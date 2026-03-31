# Repository Health Checker — Build Plan

## Overview

Org-wide repository health audit pipeline — scans all repos in a GitHub org,
checks for stale PRs, missing CI configs, outdated dependencies, open security
advisories, missing README/LICENSE, low test coverage signals, generates per-repo
scorecards, creates GitHub issues for critical findings, and produces an org-wide
health dashboard in markdown.

All scanning uses `gh` CLI commands (command phases) — no custom MCP servers needed.
Agent phases handle analysis, scoring, and report generation.

---

## Agents (4)

| Agent | Model | Role |
|---|---|---|
| **scanner** | claude-haiku-4-5 | Fast triage — reads raw scan output, normalizes findings into structured JSON |
| **analyzer** | claude-sonnet-4-6 | Scores each repo, classifies health (healthy/warning/critical), recommends actions |
| **reporter** | claude-sonnet-4-6 | Generates per-repo scorecards and org-wide dashboard markdown |
| **issue-creator** | claude-haiku-4-5 | Drafts GitHub issue bodies for critical findings, creates them via gh CLI |

### MCP Servers Used by Agents

- **filesystem** — all agents read/write JSON/markdown data files
- **github** (gh-cli-mcp) — issue-creator uses for creating/updating issues
- **sequential-thinking** — analyzer uses for multi-factor scoring reasoning

---

## Workflows (2)

### 1. `audit-org` (primary — triggered per audit run)

Main pipeline: org name in → scorecards + dashboard + issues out.

**Phases:**

1. **discover-repos** (command)
   - Command: `gh repo list {{org_name}} --json name,url,pushedAt,isArchived,defaultBranchRef --limit 200`
   - Filters out archived repos
   - Writes repo list to `data/scan-results/repo-list.json`
   - Uses `{{dispatch_input}}` for org name (falls back to config default)

2. **scan-repos** (command)
   - Script: `scripts/scan-repos.sh`
   - For each repo in `data/scan-results/repo-list.json`, runs:
     - `gh pr list -R {repo} --state open --json number,title,createdAt,author` — stale PR detection
     - `gh api repos/{owner}/{repo}/vulnerability-alerts` — security advisories
     - `gh api repos/{owner}/{repo}/contents/.github/workflows` — CI config check
     - `gh api repos/{owner}/{repo}/contents/README.md` — README existence
     - `gh api repos/{owner}/{repo}/contents/LICENSE` — LICENSE existence
     - `gh api repos/{owner}/{repo}/languages` — language breakdown
     - `gh api repos/{owner}/{repo}/commits?per_page=1` — last commit date
     - `gh api repos/{owner}/{repo}/topics` — topic tags
   - Writes raw scan data per repo to `data/scan-results/raw/{repo-name}.json`
   - Exit 0 always (individual repo failures logged but don't block pipeline)

3. **normalize-findings** (agent: scanner)
   - Reads all raw scan files from `data/scan-results/raw/`
   - Normalizes into structured findings per repo:
     - `stale_prs[]` (open > 7 days)
     - `security_advisories[]`
     - `missing_files[]` (README, LICENSE, CI config, CODEOWNERS)
     - `last_push_days_ago`
     - `language_breakdown`
     - `has_ci`, `has_tests_dir`, `has_contributing`
   - Output contract: writes `data/findings/{repo-name}.json` per repo
   - Writes `data/findings/summary.json` with aggregate counts

4. **score-repos** (agent: analyzer)
   - Reads all findings from `data/findings/`
   - Scores each repo on a 0-100 scale across dimensions:
     - **Maintenance** (25 pts): recent commits, stale PR count, branch hygiene
     - **Security** (25 pts): no open advisories, dependency audit clean
     - **Documentation** (25 pts): README exists + quality signal, LICENSE, CONTRIBUTING, CODEOWNERS
     - **CI/CD** (25 pts): has workflow configs, has test directory, topic tags present
   - Decision contract per repo: `verdict` (healthy >= 70 | warning 40-69 | critical < 40), `score`, `reasoning`, `top_issues[]`
   - Writes `data/scores/{repo-name}.json` per repo
   - Writes `data/scores/org-summary.json` with overall stats

5. **review-scores** (agent: analyzer)
   - Decision contract: `verdict` (approve | adjust), `reasoning`, `adjustments[]`
   - Sanity-checks the scoring run — looks for anomalies:
     - All repos scored critical (config issue?)
     - Score contradicts raw data (bug in scoring?)
     - Org average seems unreasonable
   - **Routing:**
     - `approve` → generate-scorecards
     - `adjust` → score-repos (rework, max 2 attempts)

6. **generate-scorecards** (agent: reporter)
   - Reads all scores from `data/scores/`
   - Generates per-repo scorecard: `output/scorecards/{repo-name}.md`
     - Overall score badge (emoji-based: green/yellow/red)
     - Dimension breakdown with scores
     - Top issues with severity
     - Recommended actions
   - Generates org-wide dashboard: `output/dashboard.md`
     - Summary table: all repos, scores, status
     - Aggregate metrics: avg score, % healthy/warning/critical
     - Trend comparison (if previous run exists in `data/history/`)
     - Top 5 most critical repos
     - Top 5 most common issues across org
   - Writes `data/history/{date}-scores.json` for trend tracking
   - Capabilities: writes_files, mutates_state

7. **triage-issues** (agent: analyzer)
   - Decision contract: `verdict` (create-issues | skip-issues), `reasoning`, `issues_to_create[]`
   - Reads critical findings — decides which warrant a GitHub issue
   - Filters: only create issues for critical repos OR warning repos with security advisories
   - Deduplicates against existing open issues (reads `data/issued-tracker.json`)
   - Each issue includes: repo, title, body, labels, severity

8. **create-issues** (agent: issue-creator)
   - Reads `issues_to_create[]` from triage decision
   - For each issue, uses gh MCP to create GitHub issue in the target repo
   - Labels: `repo-health`, `automated`, + severity (`critical`, `warning`)
   - Updates `data/issue-tracker.json` with created issue URLs
   - Capabilities: writes_files, mutates_state, requires_commit

### 2. `quick-check` (on-demand — single repo)

Lightweight single-repo health check.

**Phases:**

1. **scan-single** (command)
   - Script: `scripts/scan-single-repo.sh`
   - Same checks as scan-repos but for one repo (from `{{subject_title}}`)
   - Writes to `data/scan-results/raw/{repo-name}.json`

2. **analyze-single** (agent: analyzer)
   - Reads raw scan, scores, generates inline scorecard
   - Writes scorecard to `output/scorecards/{repo-name}.md`

---

## Data Model

### Config Files (static — read-only reference)

| File | Content |
|---|---|
| `config/org-config.yaml` | Default org name, scan exclusion patterns, scoring weights |
| `config/scoring-rubric.yaml` | Detailed scoring criteria per dimension, thresholds for healthy/warning/critical |
| `config/issue-templates.yaml` | GitHub issue body templates by finding type |

### Data Files (mutable — written by agents/scripts)

| File | Content | Writers |
|---|---|---|
| `data/scan-results/repo-list.json` | Discovered repos in org | discover-repos |
| `data/scan-results/raw/{repo}.json` | Raw scan data per repo | scan-repos.sh |
| `data/findings/{repo}.json` | Normalized findings per repo | scanner |
| `data/findings/summary.json` | Aggregate finding counts | scanner |
| `data/scores/{repo}.json` | Health score per repo | analyzer |
| `data/scores/org-summary.json` | Org-wide score summary | analyzer |
| `data/history/{date}-scores.json` | Historical scores for trends | reporter |
| `data/issue-tracker.json` | Created issues log (dedup) | issue-creator |

### Output Files (generated artifacts)

| File | Content |
|---|---|
| `output/scorecards/{repo}.md` | Per-repo health scorecard |
| `output/dashboard.md` | Org-wide health dashboard |

---

## Command Phase Scripts (3)

### `scripts/scan-repos.sh`
- Reads `data/scan-results/repo-list.json`
- Iterates repos, runs gh API calls for each check
- Writes raw JSON per repo to `data/scan-results/raw/`
- Handles rate limiting with small delays between repos
- Exit 0 always — logs per-repo errors to stderr

### `scripts/scan-single-repo.sh`
- Takes repo name as argument (from `{{subject_title}}`)
- Runs same checks as scan-repos.sh for one repo
- Writes to `data/scan-results/raw/{repo}.json`

### `scripts/validate-scores.sh`
- Optional validation: reads all score files, checks for consistency
- Ensures all discovered repos have scores
- Ensures no score exceeds 100 or is negative
- Used as a sanity gate (not in main pipeline, available for debugging)

---

## Schedules

| Schedule | Cron | Workflow |
|---|---|---|
| `weekly-org-audit` | `0 9 * * 1` (Monday 9am) | audit-org |

(`quick-check` is triggered on-demand via queue)

---

## AO Features Demonstrated

1. **Command phases with real CLIs** — gh CLI for all GitHub scanning (no custom MCP needed for reads)
2. **Multi-agent pipeline** — 4 specialized agents: scanner, analyzer, reporter, issue-creator
3. **Multi-model routing** — Haiku for fast extraction/issue drafting, Sonnet for analysis/reporting
4. **Decision contracts** — Health verdict (healthy/warning/critical), score review (approve/adjust), issue triage (create/skip)
5. **Rework loops** — Score review can send back to scoring (max 2 attempts)
6. **Scheduled automation** — Weekly org audit via cron
7. **GitHub MCP integration** — issue-creator uses gh-cli-mcp for creating issues
8. **Trend tracking** — Historical scores enable week-over-week comparison
9. **Deduplication logic** — Issue tracker prevents duplicate GitHub issues across runs

---

## Sample Data

### Sample Org Config (`config/org-config.yaml`)
```yaml
org: launchapp-dev
exclude_patterns:
  - "*.github.io"
  - "archive-*"
  - ".github"
scan_options:
  stale_pr_threshold_days: 7
  inactive_repo_threshold_days: 90
  max_repos: 200
```

### Sample Scoring Rubric (`config/scoring-rubric.yaml`)
```yaml
dimensions:
  maintenance:
    weight: 25
    checks:
      - name: recent_activity
        points: 10
        criteria: "Last push within 30 days"
      - name: stale_prs
        points: 8
        criteria: "No PRs open > 7 days"
      - name: branch_count
        points: 7
        criteria: "< 20 active branches"
  security:
    weight: 25
    checks:
      - name: no_advisories
        points: 15
        criteria: "Zero open security advisories"
      - name: dependency_audit
        points: 10
        criteria: "No critical dependency vulnerabilities"
  documentation:
    weight: 25
    checks:
      - name: readme_exists
        points: 10
        criteria: "README.md present and > 100 chars"
      - name: license_exists
        points: 8
        criteria: "LICENSE file present"
      - name: contributing_exists
        points: 4
        criteria: "CONTRIBUTING.md present"
      - name: codeowners_exists
        points: 3
        criteria: "CODEOWNERS file present"
  ci_cd:
    weight: 25
    checks:
      - name: has_workflows
        points: 12
        criteria: "At least one GitHub Actions workflow"
      - name: has_tests
        points: 8
        criteria: "Test directory or test files present"
      - name: has_topics
        points: 5
        criteria: "At least one topic tag on repo"

thresholds:
  healthy: 70
  warning: 40
  critical: 0
```

### Sample Issue Template (`config/issue-templates.yaml`)
```yaml
templates:
  missing_readme:
    title: "[Repo Health] Missing README.md"
    labels: ["repo-health", "documentation", "automated"]
    body: |
      ## Finding
      This repository is missing a README.md file.

      ## Impact
      - New contributors cannot understand the project purpose
      - Documentation score: 0/10 for this check

      ## Recommended Action
      Add a README.md with at minimum:
      - Project description
      - Setup instructions
      - Usage examples

      ---
      *Generated by [repo-health-checker](https://github.com/launchapp-dev/ao-example-repo-health-checker)*

  security_advisory:
    title: "[Repo Health] Open Security Advisory: {{advisory_title}}"
    labels: ["repo-health", "security", "automated", "critical"]
    body: |
      ## Finding
      This repository has an open security advisory that needs attention.

      ## Advisory Details
      - **Severity**: {{severity}}
      - **Package**: {{package}}
      - **Advisory**: {{advisory_url}}

      ## Recommended Action
      Update the affected dependency or apply the recommended fix.

      ---
      *Generated by [repo-health-checker](https://github.com/launchapp-dev/ao-example-repo-health-checker)*

  stale_prs:
    title: "[Repo Health] {{count}} Stale Pull Requests (>7 days)"
    labels: ["repo-health", "maintenance", "automated"]
    body: |
      ## Finding
      This repository has {{count}} pull requests open for more than 7 days.

      ## Stale PRs
      {{pr_list}}

      ## Recommended Action
      Review and either merge, close, or request changes on each stale PR.

      ---
      *Generated by [repo-health-checker](https://github.com/launchapp-dev/ao-example-repo-health-checker)*
```

### Sample Scorecard Output (`output/scorecards/ao-example-blog-generator.md`)
```markdown
# Repository Health Scorecard: ao-example-blog-generator

**Overall Score: 82/100** 🟢 Healthy

| Dimension | Score | Status |
|---|---|---|
| Maintenance | 22/25 | 🟢 |
| Security | 25/25 | 🟢 |
| Documentation | 18/25 | 🟡 |
| CI/CD | 17/25 | 🟡 |

## Top Issues
1. **Missing CONTRIBUTING.md** (documentation, -4 pts)
2. **Missing CODEOWNERS** (documentation, -3 pts)
3. **No topic tags** (ci_cd, -5 pts)

## Recommendations
- Add a CONTRIBUTING.md guide for external contributors
- Define CODEOWNERS for critical paths
- Add descriptive topic tags to improve discoverability

---
*Last scanned: 2026-03-31 | [Full dashboard](../dashboard.md)*
```

---

## Directory Structure

```
examples/repo-health-checker/
├── .ao/workflows/
│   ├── agents.yaml
│   ├── phases.yaml
│   ├── workflows.yaml
│   ├── mcp-servers.yaml
│   └── schedules.yaml
├── config/
│   ├── org-config.yaml
│   ├── scoring-rubric.yaml
│   └── issue-templates.yaml
├── scripts/
│   ├── scan-repos.sh
│   ├── scan-single-repo.sh
│   └── validate-scores.sh
├── data/
│   ├── scan-results/
│   │   └── raw/
│   ├── findings/
│   ├── scores/
│   ├── history/
│   └── issue-tracker.json
├── output/
│   ├── scorecards/
│   └── dashboard.md
├── CLAUDE.md
└── README.md
```
