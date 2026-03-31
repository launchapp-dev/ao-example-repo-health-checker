#!/usr/bin/env bash
# validate-scores.sh — Sanity check all score files after scoring phase
# Not in the main pipeline — use for debugging or manual validation
# Exits 0 if valid, 1 if anomalies found

set -uo pipefail

SCORES_DIR="data/scores"
FINDINGS_DIR="data/findings"

echo "=== Validating score files ==="

python3 << 'PYEOF'
import json
import sys
import os
from pathlib import Path

errors = []
warnings = []

scores_dir = Path("data/scores")
findings_dir = Path("data/findings")

# Load all score files
score_files = [f for f in scores_dir.glob("*.json") if f.name != "org-summary.json"]
finding_files = [f for f in findings_dir.glob("*.json") if f.name != "summary.json"]

print(f"Found {len(score_files)} score files, {len(finding_files)} finding files")

# Check all scored repos have findings
scored_repos = {f.stem for f in score_files}
found_repos = {f.stem for f in finding_files}

missing_scores = found_repos - scored_repos
if missing_scores:
    errors.append(f"Repos in findings but missing scores: {missing_scores}")

extra_scores = scored_repos - found_repos
if extra_scores:
    warnings.append(f"Repos in scores but missing findings: {extra_scores}")

# Validate each score file
for score_file in score_files:
    try:
        score = json.loads(score_file.read_text())
    except Exception as e:
        errors.append(f"{score_file.name}: JSON parse error — {e}")
        continue

    repo = score_file.stem

    # Check required fields
    for field in ['overall_score', 'status', 'dimensions']:
        if field not in score:
            errors.append(f"{repo}: missing required field '{field}'")

    # Check score range
    s = score.get('overall_score', -1)
    if not (0 <= s <= 100):
        errors.append(f"{repo}: score {s} out of valid range 0-100")

    # Check status matches score
    status = score.get('status', '')
    if s >= 70 and status != 'healthy':
        warnings.append(f"{repo}: score={s} but status='{status}' (expected healthy)")
    elif 40 <= s < 70 and status != 'warning':
        warnings.append(f"{repo}: score={s} but status='{status}' (expected warning)")
    elif s < 40 and status != 'critical':
        warnings.append(f"{repo}: score={s} but status='{status}' (expected critical)")

    # Check dimension scores don't exceed max
    dims = score.get('dimensions', {})
    for dim_name, dim in dims.items():
        dim_score = dim.get('score', 0)
        dim_max = dim.get('max', 25)
        if dim_score > dim_max:
            errors.append(f"{repo}: {dim_name} score {dim_score} exceeds max {dim_max}")

# Check org summary
summary_file = scores_dir / "org-summary.json"
if summary_file.exists():
    try:
        summary = json.loads(summary_file.read_text())
        expected_total = len(score_files)
        actual_total = summary.get('total_repos', 0)
        if actual_total != expected_total:
            warnings.append(f"org-summary total_repos={actual_total} but found {expected_total} score files")

        avg = summary.get('average_score', 0)
        if not (20 <= avg <= 90):
            warnings.append(f"Org average score {avg:.1f} is outside expected range 20-90 — check for scoring anomalies")
    except Exception as e:
        errors.append(f"org-summary.json: {e}")
else:
    warnings.append("org-summary.json not found")

# Report
if warnings:
    print(f"\n⚠️  {len(warnings)} WARNING(S):")
    for w in warnings:
        print(f"  - {w}")

if errors:
    print(f"\n❌ {len(errors)} ERROR(S):")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
else:
    print(f"\n✅ All {len(score_files)} score files are valid")
    sys.exit(0)
PYEOF
