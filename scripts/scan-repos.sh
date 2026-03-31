#!/usr/bin/env bash
# scan-repos.sh — Scan all repos discovered by discover-repos phase
# Reads data/scan-results/repo-list.json and runs gh API checks per repo
# Writes raw scan JSON to data/scan-results/raw/{repo-name}.json
# Exit 0 always — individual repo errors are logged but don't block pipeline

set -uo pipefail

REPO_LIST="data/scan-results/repo-list.json"
OUTPUT_DIR="data/scan-results/raw"
mkdir -p "$OUTPUT_DIR"

# Read org from config
ORG=$(python3 -c "
import re
content = open('config/org-config.yaml').read()
m = re.search(r'^org:\s*(\S+)', content, re.MULTILINE)
print(m.group(1) if m else 'launchapp-dev')
")

# Read rate limit delay from config (default 200ms)
DELAY=$(python3 -c "
import re
content = open('config/org-config.yaml').read()
m = re.search(r'rate_limit_delay_ms:\s*(\d+)', content)
print(float(m.group(1))/1000 if m else 0.2)
")

echo "=== Scanning repos for org: $ORG ==="
echo "Rate limit delay: ${DELAY}s between repos"

# Read repo names from list
REPOS=$(python3 -c "
import json
repos = json.load(open('$REPO_LIST'))
for r in repos:
    print(r['name'])
")

TOTAL=$(echo "$REPOS" | wc -l | tr -d ' ')
COUNT=0
ERRORS=0

while IFS= read -r REPO_NAME; do
  COUNT=$((COUNT + 1))
  FULL_NAME="$ORG/$REPO_NAME"
  OUT_FILE="$OUTPUT_DIR/${REPO_NAME}.json"

  echo "[$COUNT/$TOTAL] Scanning $FULL_NAME ..."

  # Run all checks, capturing results and HTTP status codes
  python3 - "$FULL_NAME" "$REPO_NAME" "$OUT_FILE" << 'PYEOF'
import sys
import subprocess
import json
import re
from datetime import datetime, timezone

full_name = sys.argv[1]
repo_name = sys.argv[2]
out_file = sys.argv[3]

def gh(args, capture=True):
    try:
        result = subprocess.run(
            ['gh'] + args,
            capture_output=capture,
            text=True,
            timeout=30
        )
        return result.stdout.strip(), result.returncode
    except Exception as e:
        return str(e), 1

def gh_api(endpoint, default=None):
    out, code = gh(['api', endpoint, '--silent'], capture=True)
    if code != 0:
        return default, code
    try:
        return json.loads(out), code
    except:
        return out, code

scan = {
    "repo_name": repo_name,
    "full_name": full_name,
    "scan_timestamp": datetime.now(timezone.utc).isoformat(),
    "errors": []
}

# 1. Open PRs (stale detection)
pr_out, pr_code = gh(['pr', 'list', '-R', full_name,
    '--state', 'open',
    '--json', 'number,title,createdAt,author,updatedAt',
    '--limit', '50'])
if pr_code == 0:
    try:
        scan['pr_list'] = json.loads(pr_out)
    except:
        scan['pr_list'] = []
        scan['errors'].append("Failed to parse PR list")
else:
    scan['pr_list'] = []
    scan['errors'].append(f"PR list failed: {pr_out[:200]}")

# 2. Vulnerability alerts
vuln_out, vuln_code = gh(['api', f'repos/{full_name}/vulnerability-alerts', '--silent'])
scan['vulnerability_alerts'] = {
    "status_code": 204 if vuln_code == 0 else 404,
    "enabled": vuln_code == 0,
    "raw": vuln_out if vuln_code != 0 else ""
}

# 3. Workflows directory
wf_data, wf_code = gh_api(f'repos/{full_name}/contents/.github/workflows')
scan['workflows_dir'] = {
    "status_code": 200 if wf_code == 0 else 404,
    "exists": wf_code == 0,
    "workflow_count": len(wf_data) if wf_code == 0 and isinstance(wf_data, list) else 0
}

# 4. README check
_, readme_code = gh(['api', f'repos/{full_name}/contents/README.md', '--silent'])
scan['readme_check'] = {"status_code": 200 if readme_code == 0 else 404, "exists": readme_code == 0}

# 5. LICENSE check
_, license_code = gh(['api', f'repos/{full_name}/contents/LICENSE', '--silent'])
scan['license_check'] = {"status_code": 200 if license_code == 0 else 404, "exists": license_code == 0}

# 6. CONTRIBUTING check
_, contrib_code = gh(['api', f'repos/{full_name}/contents/CONTRIBUTING.md', '--silent'])
scan['contributing_check'] = {"status_code": 200 if contrib_code == 0 else 404, "exists": contrib_code == 0}

# 7. CODEOWNERS check (could be in root, docs/, or .github/)
codeowners_exists = False
for path in ['CODEOWNERS', 'docs/CODEOWNERS', '.github/CODEOWNERS']:
    _, co_code = gh(['api', f'repos/{full_name}/contents/{path}', '--silent'])
    if co_code == 0:
        codeowners_exists = True
        break
scan['codeowners_check'] = {"exists": codeowners_exists}

# 8. Languages
lang_data, lang_code = gh_api(f'repos/{full_name}/languages')
scan['languages'] = lang_data if lang_code == 0 and isinstance(lang_data, dict) else {}

# 9. Last commit
commit_data, commit_code = gh_api(f'repos/{full_name}/commits?per_page=1')
if commit_code == 0 and isinstance(commit_data, list) and len(commit_data) > 0:
    scan['last_commit'] = commit_data[0]
else:
    scan['last_commit'] = None

# 10. Topics
topics_data, topics_code = gh_api(f'repos/{full_name}/topics',
    default={"names": []})
if isinstance(topics_data, dict):
    scan['topics'] = topics_data.get('names', [])
else:
    scan['topics'] = []

# 11. Branch count
branches_data, branches_code = gh_api(f'repos/{full_name}/branches?per_page=100')
scan['branch_count'] = len(branches_data) if branches_code == 0 and isinstance(branches_data, list) else None

with open(out_file, 'w') as f:
    json.dump(scan, f, indent=2)

if scan['errors']:
    print(f"  WARN: {len(scan['errors'])} errors for {repo_name}: {scan['errors']}", file=sys.stderr)
PYEOF

  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    ERRORS=$((ERRORS + 1))
    echo "  ERROR: Failed to scan $REPO_NAME (exit $EXIT_CODE)" >&2
  fi

  # Rate limit protection
  sleep "$DELAY"

done <<< "$REPOS"

echo ""
echo "=== Scan complete: $COUNT repos scanned, $ERRORS errors ==="
echo "Raw data written to $OUTPUT_DIR/"
exit 0
