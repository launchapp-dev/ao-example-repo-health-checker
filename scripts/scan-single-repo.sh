#!/usr/bin/env bash
# scan-single-repo.sh — Scan a single repository for the quick-check workflow
# Usage: bash scripts/scan-single-repo.sh <repo-name>
# Writes raw scan data to data/scan-results/raw/{repo-name}.json

set -euo pipefail

REPO_NAME="${1:-}"
if [ -z "$REPO_NAME" ]; then
  echo "ERROR: repo name required as first argument" >&2
  echo "Usage: bash scripts/scan-single-repo.sh <repo-name>" >&2
  exit 1
fi

# Read org from config
ORG=$(python3 -c "
import re
content = open('config/org-config.yaml').read()
m = re.search(r'^org:\s*(\S+)', content, re.MULTILINE)
print(m.group(1) if m else 'launchapp-dev')
")

FULL_NAME="$ORG/$REPO_NAME"
OUT_DIR="data/scan-results/raw"
OUT_FILE="$OUT_DIR/${REPO_NAME}.json"

mkdir -p "$OUT_DIR" "data/findings" "data/scores" "output/scorecards"

echo "=== Quick health scan: $FULL_NAME ==="

python3 - "$FULL_NAME" "$REPO_NAME" "$OUT_FILE" << 'PYEOF'
import sys
import subprocess
import json
from datetime import datetime, timezone

full_name = sys.argv[1]
repo_name = sys.argv[2]
out_file = sys.argv[3]

def gh_api(endpoint, default=None):
    try:
        result = subprocess.run(
            ['gh', 'api', endpoint, '--silent'],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return default, result.returncode
        return json.loads(result.stdout.strip()), result.returncode
    except Exception as e:
        return default, 1

def gh_cmd(args, default=None):
    try:
        result = subprocess.run(
            ['gh'] + args,
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return default, result.returncode
        try:
            return json.loads(result.stdout.strip()), result.returncode
        except:
            return result.stdout.strip(), result.returncode
    except Exception as e:
        return default, 1

scan = {
    "repo_name": repo_name,
    "full_name": full_name,
    "scan_timestamp": datetime.now(timezone.utc).isoformat(),
    "errors": []
}

print(f"  Fetching PR list...")
pr_data, pr_code = gh_cmd(['pr', 'list', '-R', full_name, '--state', 'open',
    '--json', 'number,title,createdAt,author,updatedAt', '--limit', '50'],
    default=[])
scan['pr_list'] = pr_data if isinstance(pr_data, list) else []

print(f"  Checking vulnerability alerts...")
_, vuln_code = gh_api(f'repos/{full_name}/vulnerability-alerts')
scan['vulnerability_alerts'] = {"status_code": 204 if vuln_code == 0 else 404, "enabled": vuln_code == 0}

print(f"  Checking CI workflows...")
wf_data, wf_code = gh_api(f'repos/{full_name}/contents/.github/workflows')
scan['workflows_dir'] = {
    "status_code": 200 if wf_code == 0 else 404,
    "exists": wf_code == 0,
    "workflow_count": len(wf_data) if wf_code == 0 and isinstance(wf_data, list) else 0
}

print(f"  Checking documentation files...")
_, readme_code = gh_api(f'repos/{full_name}/contents/README.md')
scan['readme_check'] = {"status_code": 200 if readme_code == 0 else 404, "exists": readme_code == 0}

_, license_code = gh_api(f'repos/{full_name}/contents/LICENSE')
scan['license_check'] = {"status_code": 200 if license_code == 0 else 404, "exists": license_code == 0}

_, contrib_code = gh_api(f'repos/{full_name}/contents/CONTRIBUTING.md')
scan['contributing_check'] = {"status_code": 200 if contrib_code == 0 else 404, "exists": contrib_code == 0}

codeowners_exists = False
for path in ['CODEOWNERS', 'docs/CODEOWNERS', '.github/CODEOWNERS']:
    _, co_code = gh_api(f'repos/{full_name}/contents/{path}')
    if co_code == 0:
        codeowners_exists = True
        break
scan['codeowners_check'] = {"exists": codeowners_exists}

print(f"  Fetching languages and topics...")
lang_data, _ = gh_api(f'repos/{full_name}/languages', default={})
scan['languages'] = lang_data if isinstance(lang_data, dict) else {}

commit_data, _ = gh_api(f'repos/{full_name}/commits?per_page=1', default=[])
scan['last_commit'] = commit_data[0] if isinstance(commit_data, list) and commit_data else None

topics_data, _ = gh_api(f'repos/{full_name}/topics', default={"names": []})
scan['topics'] = topics_data.get('names', []) if isinstance(topics_data, dict) else []

branches_data, _ = gh_api(f'repos/{full_name}/branches?per_page=100', default=[])
scan['branch_count'] = len(branches_data) if isinstance(branches_data, list) else None

with open(out_file, 'w') as f:
    json.dump(scan, f, indent=2)

print(f"  Written to {out_file}")
PYEOF

echo "=== Scan complete for $REPO_NAME ==="
echo "Raw data: $OUT_FILE"
