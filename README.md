# delegate-agents

A Claude Code plugin that lets Claude act as an **orchestrator**: it plans and verifies, and hands the coding to headless workers — **Codex**, **Antigravity (agy)** or another **headless Claude** — so you can spend other vendors' tokens and get cross-vendor review.

## What it does

- **Research first** — for new functionality, Claude asks a few clarifying questions, then a research worker searches the web for existing repos, templates, libraries and services. You get a comparison report (fit, stack, licence, maintenance, risks, verified links) and choose; only then is an implementation plan written.
- **Strict roles** — Claude splits the plan, writes worker instructions, verifies and merges. A cheap Surveyor maps the codebase before every plan (structure, conventions, what to reuse, risks), using graphify when installed. Workers implement only what they are told, with TDD. Review always goes to a different vendor than the one that wrote the code.
- **`run-agent.sh`** — one wrapper for all three CLIs (flags, timeout, closed stdin, read-only mode) that logs every worker to `.agents/status.jsonl`.
  `RESUME=<id>` continues a worker's own session (fix loops), `run-agent.sh stop <id>` cancels a running worker, and verified transient errors (network drop, model at capacity) are resumed automatically up to 2 times (`RETRY=0` disables).
- **Live dashboard** — a local page showing the worker tree, each worker's conversation, and quota for every vendor (refreshed every 5 minutes at no token cost).
- **Quota-aware routing** — `quota.py pick` moves a task to another vendor when the preferred one is running low.
- **Parallel waves** — `waves.py` reads a [superpowers](https://github.com/obra/superpowers) writing-plans plan and groups tasks into waves; tasks in one wave share no files and no dependencies, so they run in parallel worktrees.
- **Lesson book** — a Stop hook makes Claude record verified lessons (per machine) and a per-repo progress report after every merge.

## Requirements

- [Claude Code](https://claude.com/claude-code)
- At least one worker CLI, logged in: `codex` (≥ 0.170), `agy` (≥ 1.5.12) or `claude`
- `python3` (stdlib only), `bash`, `git`, `curl`
- Recommended on every vendor you use: the [superpowers](https://github.com/obra/superpowers) and [ponytail](https://github.com/DietrichGebert/ponytail) plugins (workers are told to use them; plain-text fallbacks apply when missing). Optional: [graphify](https://github.com/Graphify-Labs/graphify) for cheaper codebase surveys.

## Install

```bash
claude plugin marketplace add DongNQ247/delegate-agents
claude plugin install delegate-agents@delegate-agents
```

Restart Claude Code. Update later with:

```bash
claude plugin marketplace update delegate-agents
claude plugin update delegate-agents@delegate-agents
```

## Usage

Just ask Claude, for example:

- "Build a small shop website." → a few questions → research report in `.agents/research/` → you pick → plan → workers build it.
- "Hand this task to Codex."
- "Implement this plan with agy workers and have Codex review."
- "Execute `docs/superpowers/plans/<plan>.md` in parallel waves."

The skill loads automatically. It opens the dashboard, dispatches workers, verifies their results itself, and merges.

## Data

Per-machine data lives in the plugin data folder (`~/.claude/plugins/data/delegate-agents-delegate-agents/`) and survives updates:

| File | Contents |
|---|---|
| `LESSONS.md` | lessons learned on this machine; created from `LESSONS.template.md` on first use |
| `state/quota.json` | latest quota snapshot per vendor |

Inside each project you work on, the skill keeps `AGENTS.md` (committed, shared instructions for all agents) and `.agents/` (git-excluded: logs, dashboard, `REPORT.md`, `research/` reports).

## Layout

```
.claude-plugin/   plugin.json, marketplace.json
hooks/            hooks.json, lessons-hook.py (Stop hook)
scripts/          run-agent.sh, quota.py, waves.py, dashboard.sh, dashboard.html, stream_normalize.py
skills/delegate-agents/SKILL.md   main skill (entry point)
skills/research/SKILL.md          research phase
tests/
LESSONS.template.md
```

## Development

```bash
python3 -m pytest tests/
bash tests/test_run_agent.sh
bash tests/test_dashboard.sh
node tests/test_dashboard_js.js
claude plugin validate .
```

`tests/test_dashboard.sh` has a known timing flake (about 1 run in 12); re-run it once before investigating.
Bump `version` in `.claude-plugin/plugin.json` on every change, or installed copies won't update.
