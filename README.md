# Repository Health Checker

Org-wide GitHub repository health audit pipeline — scans every repo in your org, scores it across four dimensions, generates per-repo scorecards and an org-wide dashboard, and automatically creates GitHub issues for critical findings.

## Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AUDIT-ORG WORKFLOW  (runs weekly via cron, or on-demand)                   │
│                                                                             │
│  discover-repos          scan-repos          normalize-findings             │
│  (command: gh repo       (command: bash      (agent: scanner/haiku)         │
│   list → JSON)    ──▶    scan-repos.sh) ──▶  normalize raw → findings JSON  │
│                                                          │                  │
│                                                          ▼                  │
│  review-scores ◀──────── score-repos                                        │
│  (agent: analyzer)       (agent: analyzer/sonnet)                           │
│  decision: approve /     4-dimension scoring,                               │
│  adjust (→ rework)       0-100 scale                                        │
│       │ approve                                                              │
│       ▼                                                                     │
│  generate-scorecards ──▶ triage-issues ──▶ create-issues                   │
│  (agent: reporter)       (agent: analyzer)  (agent: issue-creator/haiku)   │
│  per-repo .md +          decide which       gh MCP → GitHub issues          │
│  dashboard.md            findings → issues  dedup via issue-tracker.json    │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────┐
│  QUICK-CHECK WORKFLOW           │
│  (on-demand, single repo)       │
│                                 │
│  scan-single ──▶ analyze-single │
│  (command)       (agent)        │
│  bash scan-      score + write  │
│  single-repo.sh  scorecard.md   │
└─────────────────────────────────┘
```

## Quick Start

```bash
# Prerequisites
gh auth login          # Authenticate with GitHub
export GH_TOKEN=$(gh auth token)

# Run a full org audit
cd examples/repo-health-checker
ao daemon start
ao queue enqueue \
  --title "org-audit-$(date +%Y%m%d)" \
  --description "Weekly health audit" \
  --workflow-ref audit-org

# Check results
cat output/dashboard.md
ls output/scorecards/

# Quick single-repo check
ao queue enqueue \
  --title "my-repo-name" \
  --description "Quick health check for my-repo-name" \
  --workflow-ref quick-check

# Or let it run automatically (Monday 9am)
ao daemon start --autonomous
```

## Agents

| Agent | Model | Role |
|---|---|---|
| **scanner** | claude-haiku-4-5 | Normalizes raw gh CLI output into structured findings JSON |
| **analyzer** | claude-sonnet-4-6 | Scores repos 0-100, reviews scoring for anomalies, triages issues |
| **reporter** | claude-sonnet-4-6 | Generates per-repo scorecards and org-wide dashboard markdown |
| **issue-creator** | claude-haiku-4-5 | Creates GitHub issues for critical findings via gh-cli-mcp |

## Scoring Dimensions

Each repo is scored on a **0-100 scale** across four equal dimensions (25 pts each):

| Dimension | What It Checks |
|---|---|
| **Maintenance** | Recent commits, stale PRs (>7 days), branch count |
| **Security** | Open security advisories, dependency vulnerabilities |
| **Documentation** | README, LICENSE, CONTRIBUTING.md, CODEOWNERS |
| **CI/CD** | GitHub Actions workflows, test directory signals, topic tags |

**Status thresholds:** 🟢 Healthy ≥70 · 🟡 Warning 40-69 · 🔴 Critical <40

## AO Features Demonstrated

1. **Command phases with real CLIs** — gh CLI for all GitHub scanning (no custom MCP needed for reads)
2. **Multi-agent pipeline** — 4 specialized agents with different models and responsibilities
3. **Multi-model routing** — Haiku for fast extraction/issue drafting, Sonnet for deep analysis
4. **Decision contracts** — Health verdict routing, score review (approve/adjust), issue triage
5. **Rework loops** — Score review can send back to scoring phase (max 2 attempts)
6. **Scheduled automation** — Weekly org audit via cron (Monday 9am)
7. **GitHub MCP integration** — issue-creator uses gh-cli-mcp for creating issues
8. **Trend tracking** — Historical scores in data/history/ enable week-over-week comparison
9. **Deduplication logic** — issue-tracker.json prevents duplicate GitHub issues across runs

## Output

```
output/
├── dashboard.md              # Org-wide health summary with all repos ranked
└── scorecards/
    ├── repo-name-1.md        # Per-repo scorecard with score, issues, recommendations
    ├── repo-name-2.md
    └── ...

data/
├── scan-results/
│   ├── repo-list.json        # Discovered repos
│   └── raw/{repo}.json       # Raw gh CLI output per repo
├── findings/{repo}.json      # Normalized findings per repo
├── scores/{repo}.json        # Health scores per repo
├── scores/org-summary.json   # Aggregate org stats
├── history/{date}-scores.json # Historical snapshots for trends
└── issue-tracker.json        # Dedup log of created GitHub issues
```

## Requirements

| Requirement | Details |
|---|---|
| `gh` CLI | GitHub CLI, authenticated (`gh auth login`) |
| `GH_TOKEN` | GitHub token with `repo` scope for private repos |
| `python3` | Standard library only — used in scan scripts |
| `@modelcontextprotocol/server-filesystem` | npm package (auto-installed via npx) |
| `@modelcontextprotocol/server-sequential-thinking` | npm package (auto-installed via npx) |
| `gh-cli-mcp` | npm package (auto-installed via npx) |

## Configuration

Edit `config/org-config.yaml` to set your org name and scan options:

```yaml
org: your-github-org          # GitHub org to audit
scan_options:
  stale_pr_threshold_days: 7  # PRs older than this are flagged
  max_repos: 200               # Cap on repos to scan
  rate_limit_delay_ms: 200     # Delay between repo scans
```

Edit `config/scoring-rubric.yaml` to adjust scoring weights and thresholds.
