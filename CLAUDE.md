# Repository Health Checker — Agent Context

This is an **org-wide repository health audit pipeline** built on AO. It scans all repos
in a GitHub org, scores them across four dimensions, generates scorecards, and creates
GitHub issues for critical findings.

## What This Project Does

1. **Discovers** all active repos in a GitHub org via `gh repo list`
2. **Scans** each repo with targeted gh API calls (PRs, advisories, file checks, CI)
3. **Normalizes** raw scan data into structured findings JSON (scanner agent)
4. **Scores** each repo 0-100 across maintenance/security/documentation/CI (analyzer agent)
5. **Reviews** scoring for anomalies — can rework if scoring looks off (analyzer)
6. **Generates** per-repo scorecards + org-wide dashboard markdown (reporter agent)
7. **Triages** which findings warrant GitHub issues (analyzer)
8. **Creates** GitHub issues for critical findings (issue-creator agent + gh MCP)

## Directory Layout

```
config/
├── org-config.yaml        # Org name, scan settings, exclusion patterns
├── scoring-rubric.yaml    # Scoring criteria per dimension (weights, partial credit)
└── issue-templates.yaml   # GitHub issue body templates by finding type

scripts/
├── scan-repos.sh          # Batch scan all repos (used in scan-repos phase)
├── scan-single-repo.sh    # Single repo scan (used in quick-check workflow)
└── validate-scores.sh     # Debugging tool — validates score file consistency

data/
├── scan-results/repo-list.json     # Discovered repos
├── scan-results/raw/{repo}.json    # Raw scan output per repo
├── findings/{repo}.json            # Normalized findings
├── findings/summary.json           # Aggregate finding counts
├── scores/{repo}.json              # Health scores
├── scores/org-summary.json         # Org-wide score aggregate
├── history/{date}-scores.json      # Historical snapshots for trend tracking
└── issue-tracker.json              # Log of created issues (prevents duplicates)

output/
├── dashboard.md                    # Org-wide health dashboard
└── scorecards/{repo}.md            # Per-repo scorecard
```

## Scoring Rubric Summary

**Maintenance (25 pts)**
- Recent activity (10): last push ≤30 days
- No stale PRs (8): zero PRs open >7 days
- Branch hygiene (7): <10 active branches

**Security (25 pts)**
- No advisories (15): zero open vulnerability alerts
- Dependency audit (10): no critical/high CVEs

**Documentation (25 pts)**
- README.md (10)
- LICENSE (8)
- CONTRIBUTING.md (4)
- CODEOWNERS (3)

**CI/CD (25 pts)**
- Has Actions workflows (12)
- Has tests directory (8)
- Has topic tags (5)

**Thresholds:** Healthy ≥70, Warning 40-69, Critical <40

## Key Conventions

- **Issue deduplication**: Always check `data/issue-tracker.json` before creating any GitHub issue.
  Match on `repo` + `finding_type` to determine if an open issue already exists.
- **History files**: Named `data/history/YYYY-MM-DD-scores.json`. Reporter writes these.
- **Score file naming**: Use the short repo name (not `org/repo`), e.g., `ao-example-blog-generator.json`
- **Error handling**: Scan scripts always exit 0. Per-repo errors are logged but never block the pipeline.
- **Rate limiting**: scan-repos.sh sleeps between repos. The delay is configured in org-config.yaml.

## Running Manually

```bash
# Full org audit
ao workflow run audit-org

# Single repo
ao queue enqueue --title "my-repo" --workflow-ref quick-check

# Validate scores after scoring phase
bash scripts/validate-scores.sh

# Watch live
ao daemon stream --pretty
```

## GitHub Token Scopes Required

- `repo` — read private repos, create issues
- `read:org` — list org repos
- Vulnerability alerts require the org to have them enabled (Settings → Security)
