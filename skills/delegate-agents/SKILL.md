---
name: delegate-agents
description: Use when the user asks to build something new (build / add a feature / make a website or app), to hand work to Codex, Antigravity (agy) or a headless Claude, to use other vendors' agent tokens, to pick a model or reasoning effort for a delegated task, to get a cross-vendor code review, or when executing a plan whose independent tasks could run on another agent.
---

# Delegate to Codex / agy / Claude

Claude (this session) stays orchestrator (plan, split, verify). Workers run headless via Bash.
Pick flat vs two-level vs mixed per run — see "Choosing the shape".

## Start here

- New functionality (a feature, website, app, integration) → run delegate-agents:research first.
- Bug fix, refactor, or internal-only change → skip research; say in one line why (e.g. "Bug fix: no research needed").
- Then **always** (features, fixes, refactors; after `## Decision` when research ran) → survey (see "Survey prompt") → superpowers:writing-plans from the research + survey reports → the workflow below.
- Before the plan, write the acceptance criteria to `<repo>/.agents/criteria/YYYY-MM-DD-<topic>.md`: a numbered list in the user's words (features: from Clarify and `## Decision`; bug fixes: "bug no longer reproduces" + repro steps).
- After the last merge → delegate-agents:acceptance (Tester checks every criterion), then hand-off.
- While planning you may run at most two short `graphify query "<q>" --budget 800` follow-ups; never read the codebase yourself.

**Lesson book — `${CLAUDE_PLUGIN_DATA}/LESSONS.md`:**
- Start of a run: seed it if missing with `[ -f ${CLAUDE_PLUGIN_DATA}/LESSONS.md ] || { mkdir -p ${CLAUDE_PLUGIN_DATA} && cp ${CLAUDE_PLUGIN_ROOT}/LESSONS.template.md ${CLAUDE_PLUGIN_DATA}/LESSONS.md; }`, then read it, and copy only the lines relevant to a worker into that worker's prompt. Workers never read the whole book.
- End of a run: append verified lessons in its entry format (date, tags, what happened → rule, evidence, status). Only you write; worker and survey problems arrive through their summaries.
- An entry that repeats or gets proven → move its rule into SKILL.md and delete it from LESSONS.md.

**Per-project files (in the repo you're working on):**
| File | Git | Holds | Updated |
|---|---|---|---|
| `AGENTS.md` (+ symlinks `CLAUDE.md`, `GEMINI.md` → it) | committed | stable instructions for every agent: test command, layout, helpers to reuse, conventions | rarely, when a project rule is confirmed |
| `.agents/REPORT.md` | git-excluded | progress report, one entry per merged task: date · task · commit · who (agent/model per role) · tests · review findings · open items | after **every** merged task, by you only |

- First run in a repo: create both if missing. Build `AGENTS.md` from what exists (test command, modules), not from guesses. Verified: Codex, agy and Claude all auto-load it (answered a repo-only question with no tools).
- Promote: a REPORT finding that is a project rule → `AGENTS.md`; a finding true for every project → `LESSONS.md`.
- The Surveyor reads `AGENTS.md` too, so keep its "reuse" list current. That makes the survey cheaper.
- A Stop hook (`hooks/lessons-hook.py`, in the plugin's `hooks/hooks.json`) blocks a stop only after a `git merge` (in a session that used `run-agent.sh`) until LESSONS.md and `.agents/REPORT.md` have been handled since that merge. Answer by updating the file(s), or by one line saying there is nothing new. It reads only your own Bash/Write/Edit calls and text, with quoted strings ignored, so fixtures, `ls`/`grep` output and prompts don't trigger it. Self-test: `python3 -m pytest ${CLAUDE_PLUGIN_ROOT}/tests`.

**REQUIRED:** superpowers:verification-before-completion (accepting a worker's result is a completion claim).
**Where this fits superpowers:** in superpowers:subagent-driven-development, this skill is how you *dispatch the implementer* to Codex/agy instead of a Claude subagent. Keep that skill's per-task spec-compliance review and code-quality review — do them yourself or send them cross-vendor (rule 5). Worktrees: superpowers:using-git-worktrees; parallel dispatch: superpowers:dispatching-parallel-agents.
Codex and agy have superpowers and ponytail installed too (`codex plugin list`, `agy plugin list`); name the skills in every prompt (see "Skills by role") — never rely on hooks or auto-triggering in headless runs. 
`codex mcp-server` no longer exists (codex-cli ≥0.170) and agy has no MCP server — use the CLI.

## Roles (strict separation)

| Role | Who | Does | Never |
|---|---|---|---|
| Orchestrator | you (Claude; always Claude) | split the plan, decide from the survey's reuse table, write worker instructions, verify, merge, clean | research the codebase or the web itself; write code |
| Researcher (new functionality only) | Codex `gpt-6-luna` medium, `MODE=ro`, web search (id `research-<topic>`); agy fallback | external prior art: repos, templates, libraries, services → comparison report via delegate-agents:research | choose for the user; edit files |
| Surveyor | Codex `gpt-6-luna` low, `MODE=ro` (id `survey-<topic>`) — measured 30s vs agy gemini-flash 394s (high: timed out at 300s), same accuracy | before every plan: structure, conventions, reuse table, risks → survey report | edit files; decide; implement |
| Test-writer (risky tasks only) | a vendor different from the implementer | failing tests from your acceptance cases, before any code exists; commit-ready test file only | write implementation code |
| Tester (end of run) | vendor per delegate-agents:acceptance recipe, `MODE=ro` unless it must serve (id `test-<topic>`) | end-of-run acceptance check of the merged product vs the criteria file | edit code; change criteria |
| Worker | Codex / agy / Claude | exactly the instructed task, with the reuse it was told to use; unit tests via TDD | explore or research beyond the files named; add dependencies; edit tests it was given |

### Skills by role

Name these in the worker prompt, word for word. If a vendor lacks one (`codex plugin list`, `agy plugin list`, `claude plugin list`), paste the fallback line instead.

| Role | Prompt line | Fallback if missing |
|---|---|---|
| Researcher | follows delegate-agents:research (its own prompt) | — |
| Surveyor | graphify CLI when on PATH (see Survey prompt) | `rg`/`ls` |
| Worker | "Use the ponytail skill and superpowers:test-driven-development." | "Smallest change that fully works; reuse before writing; no unrequested features or dependencies. Write the failing test first." |
| Worker on a hard bug | add "Use superpowers:systematic-debugging." | "Find the root cause before changing code." |
| Reviewer | "Use the ponytail-review skill." | "Review correctness, safety, tests vs acceptance cases, and lines that aren't needed." |

Verified 2026-11-20: headless `codex exec` and `agy -p` both read ponytail's SKILL.md when the prompt names it (ponytail 5.3.3).

Run the survey before every plan. A single trivial task may go straight to a worker.

### Survey prompt (fill `<change>`)

First: `command -v graphify >/dev/null && (cd <abs repo> && graphify update .)` (AST only, no LLM, incremental; never `--mode deep` unless the user asks). Then:
`TIMEOUT=600 MODE=ro AGENTS_LOG=<abs repo>/.agents/status.jsonl bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh codex gpt-6-luna low <abs repo> survey-<topic> - "$(cat <prompt file>)"`

```
You are the Surveyor. Do not edit files. Do not implement anything.
Repo: <abs path>. Change planned: <change>
If graphify-out/graph.json exists, use `graphify query "<q>" --budget 1500`, `graphify path "A" "B"`, `graphify explain "X"` first; otherwise `rg`/`ls`. Open only the files they point to.
For the reuse table, walk this ladder per piece of the change and stop at the first rung that fully covers it:
1 not needed / already done  2 exists in this codebase  3 standard library / platform  4 already-installed dependency  5 new code (minimal)
Flag pieces that would each create the same new helper (SHARED).
Output ONLY these four sections, each at most ~25 lines; every path you cite must exist:
## Structure — files/modules the change touches and how they relate
## Conventions — test command, naming, patterns to follow, how to run the product and check it by hand
## Reuse — table: ID | VERDICT (DROP|REUSE|STDLIB|DEP|SHARED|NEW) | evidence (file:symbol, module, or package) | one-line instruction
## Risks — fragile or untested areas the change touches
```

You then check each evidence path exists (one `grep`/`ls`, not a re-research), save the report to `<repo>/.agents/survey/YYYY-MM-DD-<topic>.md`, promote stable facts (test command, layout, reuse list) to `AGENTS.md`, and turn the table into plan tasks and worker instructions: DROP → no task; REUSE/STDLIB/DEP → name the exact symbol to use; SHARED → one task builds the helper first, the others run after it merges; NEW → normal task.

### Who writes tests

- You (orchestrator) write **acceptance cases** in every worker prompt: concrete inputs → expected outputs/errors, including edge cases. That is a spec, not test code.
- The worker writes unit tests via TDD (prompt line in "Skills by role").
- The cross-vendor reviewer checks the tests against the acceptance cases and lists missing edge cases.
- **Risky code** (money, security, parsing untrusted input, user data): add a separate test-writer from a different vendor than the implementer. It writes the failing test file first. You commit that file on the task branch. The implementer is told "tests in <file> are given; do not edit them". You verify with `git diff <test-commit> -- <test file>`, which must be empty.

Why: an agent that writes both code and tests confirms its own misreading. agy's `hex_to_rgb` passed its own tests while accepting "+1+2+3", and a Codex review caught it.

### Worker instruction contract

Every worker prompt contains: goal · files to touch · what to reuse (from the survey) · acceptance cases · test command · "Use the ponytail skill and superpowers:test-driven-development. Do not search the codebase or add dependencies beyond this. If the instructed reuse does not work, stop and report why instead of finding another way. Do not commit. Reply with a one-line summary."



Never rely on defaults: they change with config/updates and hide cost. Every call states model and effort explicitly.

| Worker | Flags | Choices (check live: `agy models`; `~/.codex/config.toml`) |
|---|---|---|
| Codex | `-m <model> -c model_reasoning_effort=<low\|medium\|high\|xhigh>` | `gpt-6-luna` (user default, medium) |
| agy | `--model <slug>`; add `--effort` only for slugs without a built-in level (Gemini slugs already end in -low/-medium/-high; agy rejects both) | `gemini-3.8-flash-{low,medium,high}`, `claude-opus-4-6-thinking`, `claude-sonnet-4-6`, `gpt-oss-120b-medium` |
| Claude headless | `claude -p --model <haiku\|sonnet\|opus> --effort <level>` | aliases resolve to latest |
| Claude in-session | Agent tool, `model: haiku\|sonnet\|opus` | for tasks needing this session's context |

Effort by task:

| Task | Effort | Suggested worker |
|---|---|---|
| Mechanical: rename, boilerplate, format, simple tests | low | agy `gemini-3.8-flash-low` or Codex low |
| Normal plan task with clear acceptance test | medium | Codex `gpt-6-luna` medium |
| Tricky logic, cross-file refactor | high | Codex high, or agy `claude-opus-4-6-thinking` |
| Large-codebase read / summary / research | medium | agy `gemini-3.8-flash-high` (big context, fast) |
| Second review of another vendor's code | high | whichever vendor did NOT write it |

agy model quota is routed by pool: `gemini-*` uses Gemini; `claude-*` and `gpt-*` use Claude & GPT. Apply the same switch thresholds as other vendors: 5h ≥85% or week ≥90%.
Don't ask a worker which model it is: self-reports are wrong (Codex pinned to gpt-6-luna answered "GPT-6.2-Sol"). Trust the flag.
agy fails fast on an unknown slug (prints the model list) — no silent fallback.

## Commands (verified codex-cli 0.170, agy 1.5.12)

| Role | Command |
|---|---|
| Codex writes code | `timeout 600 codex exec -s workspace-write -m M -c model_reasoning_effort=E -C <dir> -o <out.txt> "<task>" >/dev/null 2>&1; cat <out.txt>` |
| Codex read-only | same with `-s read-only` |
| agy review / research | `cd <dir> && timeout 600 agy -p "<task>. Do not edit files." --model M --sandbox --dangerously-skip-permissions` |
| agy writes code | `cd <dir> && timeout 600 agy -p "<task>" --model M --mode accept-edits --dangerously-skip-permissions` |
| Claude headless writes code | `cd <dir> && timeout 600 claude -p "<task>" --model M --effort E --permission-mode acceptEdits --allowedTools "Bash(python3 -m pytest:*)"` (adapt the allowed test command; acceptEdits alone blocks Bash, so it cannot run tests) |

- Codex: `-o` keeps only the final message; stdout is a long log — discard it. Repo instructions for Codex go in `AGENTS.md` (auto-loaded).
- agy `--sandbox` (MODE=ro) is advisory, not a sandbox: with `--dangerously-skip-permissions` it has run host commands (a Windows `taskkill` via WSL interop). Never give agy tasks that tempt it to drive host apps (browsers, desktop apps); use it for reading, research and review.
- agy headless auto-denies any tool permission (`jetski: no output produced`) unless `--dangerously-skip-permissions`; pair it with `--sandbox` when read-only. Needs one prior interactive login.
- Long tasks: run with Bash `run_in_background: true`; you're notified on exit.

## Run through run-agent.sh + live dashboard (preferred)

`run-agent.sh` (this folder) wraps all three workers with the flags above, `</dev/null` stdin, timeout, and logs start/end to a JSONL file that `dashboard.html` renders as a live tree (who manages whom).

**Always start it automatically** when a run dispatches workers (no need to ask the user):
```bash
CLAUDE_PLUGIN_DATA=${CLAUDE_PLUGIN_DATA} bash ${CLAUDE_PLUGIN_ROOT}/scripts/dashboard.sh start <abs repo>   # idempotent; opens the browser; prints AGENTS_LOG=… and the URL
# each worker (parallel: one `&` per line, then wait):
AGENTS_LOG=<abs repo>/.agents/status.jsonl bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh <codex|agy|claude> <model> <effort|-> <abs worktree> <id> <parent-id|-> "<prompt>"
# end of run (rule 6):
CLAUDE_PLUGIN_DATA=${CLAUDE_PLUGIN_DATA} bash ${CLAUDE_PLUGIN_ROOT}/scripts/dashboard.sh stop <abs repo>
```
- `start` creates `.agents/`, refreshes dashboard.html, git-excludes `.agents/`, picks a free port from 8765, and runs the server detached (survives the Bash call). It binds 127.0.0.1, answers only `localhost`/`127.0.0.1` Host headers, and serves only dashboard.html, status.jsonl, quota.json and `<id>.events.jsonl` (prompts, raw/err/out logs and reports stay off the wire). Running it again reuses the server and reopens the page. Tell the user the printed URL once.
- `NO_OPEN=1` skips the browser (e.g. a sub-orchestrator).
- `parent` = id of the sub-orchestrator that launched it; `-` = launched by you (shown under "orchestrator").
- `MODE=ro` for reviews; `TIMEOUT=` seconds; `ALLOWED_TOOLS=` Bash rule for a claude worker; `WAVE=N`; `RESUME=<id>`; `RETRY=` (default 2, `0` disables); `RETRY_WAIT=` (default `"30 90"` seconds).
- Fix loop: send the reviewer's findings to the implementer's own session with `RESUME=<implementer id>`, same agent, new id `<id>-fixN`, same parent. The prompt holds only the findings, not the full brief again. No `.agents/<id>.session` (or a different agent) → exit 2; start a new worker instead.
- Stop a worker: `AGENTS_LOG=<abs repo>/.agents/status.jsonl bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh stop <id>` kills its process group; final status `cancelled`. Exit 1 = not running (unknown or already finished).
- Retry: after a failure matching a known transient error (Codex stream disconnect / model at capacity, Claude "Connection lost mid-response"; agy has none on record), run-agent waits 30s then 90s and resumes the same session with "Continue the task…", at most `RETRY` times; each retry is a `retry N` line in status.jsonl. Real failures, timeouts, usage limits and stops are never retried. `RETRY=0` turns it off.
- Full worker output: `$R/.agents/<id>.out`.
- All three vendors refresh for free every 5 minutes through one per-user dashboard refresher. Claude runs `claude -p /usage`; Codex reads session files because `codex exec /status` sends a model request and is not free; agy runs `agy -p /usage`. `pick` refreshes quota data when it is older than 5 minutes. State files are `state/quota.json` and `state/refresher.pid`.
- The Claude refresh uses `--no-session-persistence` so it adds no history, but the user's hooks still run on each refresh (about every 5 minutes).
- `DELEGATE_CLAUDE_BIN` and `DELEGATE_AGY_BIN` override the Claude and agy executables; `DELEGATE_AGY_INTERVAL` sets the shared refresh interval (default 300 seconds). `DELEGATE_QUOTA` and `DELEGATE_CODEX_SESSIONS` are test-only environment overrides.
- Before each dispatch, choose by capability first, then run `CLAUDE_PLUGIN_DATA=${CLAUDE_PLUGIN_DATA} python3 ${CLAUDE_PLUGIN_ROOT}/scripts/quota.py pick <preferred|-> <eligible...>`; it prints `vendor<TAB>reason`. Include agy candidates as `agy:<model>`, e.g. `CLAUDE_PLUGIN_DATA=${CLAUDE_PLUGIN_DATA} python3 ${CLAUDE_PLUGIN_ROOT}/scripts/quota.py pick claude claude codex agy:claude-sonnet-4-6`. `gemini-*` uses the Gemini pool; `claude-*` and `gpt-*` use the Claude & GPT pool. Bare `agy` and unknown model names have unknown quota and are never switch targets. Two agy models count as one vendor for cross-vendor review. If the selected vendor differs from the preferred vendor, pass `ROUTED_FROM=<preferred> ROUTE_REASON=<reason>` to `run-agent.sh`.
- Pass at most one `agy:<model>` per `pick`, and dispatch exactly that model when `pick` returns `agy`.
- Worker streams create `.agents/<id>.events.jsonl`, `.agents/<id>.raw.jsonl`, and `.agents/<id>.err`. Quota snapshots are stored in the per-user `state/quota.json`. These files are git-ignored. The dashboard defaults to the running status chip and also filters done, failed, or all agents; quota cards are yellow, green, or red and agy has Gemini and Claude & GPT pools.
- Sub-orchestrator (claude) launching children: headless Claude blocks compound commands (`export …; (… & …)` → "can't be checked before it runs"). Give it `ALLOWED_TOOLS="Bash(MODE=ro bash <run-agent path>:*)"` (or without `MODE=ro`) and tell it to send one Bash call per child, in parallel, no cd/export. AGENTS_LOG is inherited.

## Routing

| Task | Send to |
|---|---|
| Well-specified implementation task from a plan | Codex |
| Read/summarize a large codebase, research, second review | agy (route as `agy:<model>` for quota-aware picks) |
| Planning, architecture, hard debugging, final review, merge conflicts | Claude (this session) |

## Rules

1. Each task prompt is self-contained: goal, files, acceptance check (test command), "reply with a one-line summary".
2. Route by capability first. agy shares routing by pool: `gemini-*` uses Gemini; `claude-*` and `gpt-*` use Claude & GPT. Switch vendors only when the preferred pool/vendor has 5h used ≥85% or week used ≥90%; on a tie, pick the eligible vendor with more headroom. A bare `agy` or unknown model has unknown quota and cannot be a switch target. In a cross-vendor review, two agy models count as one vendor; with only one eligible vendor, warn only. Record every switch in `REPORT.md`.
3. Parallel writers each get their own worktree — never two writers in one tree. See "Parallel + merge".
4. Never trust the agent's summary: run the tests and read `git diff` yourself before accepting.
5. Cross-vendor review: code written by Codex → review by agy or Claude, not Codex. The review prompt starts "Use the ponytail-review skill." and asks: "Is the code correct? Do the tests cover these acceptance cases: <list>? List missing edge cases."
6. Whoever creates a worktree/branch/server owns merging and cleanup. Workers never merge or clean. A sub-orchestrator hands up only a merged, tested, clean area branch. You (root) finish into master via superpowers:finishing-a-development-branch, stop the dashboard (`dashboard.sh stop <repo>`), and keep `.agents/` logs (git-excluded).
7. Don't end your turn while a worktree, task branch or server you created still exists — unless the user asked to keep it. Check: `git worktree list`, `git branch`, background tasks.

## Parallel + merge

1. Commit a clean base first (worktrees branch from HEAD; uncommitted work is not in them).
2. `git worktree add ../wt-<task> -b <task>` per task.
3. Launch all agents in one Bash call, each as `( ... ) &`, then `wait` — or each with `run_in_background: true`. Tell them "Do not commit".
4. Per worktree: run the tests, read `git diff`, then you commit (`git add -A && git commit -m <task>`).
5. In the main tree: `git merge --no-edit <task>` one branch at a time; run tests after each merge.
6. Conflict: expected when tasks append to the same file or edit the same import line. If both sides are additions, keep both, run tests, commit. If the logic truly conflicts, resolve it yourself (Claude) — don't re-delegate a conflicted tree.
7. Clean up: `git worktree remove ../wt-<task> && git branch -d <task>`.

To reduce conflicts, split tasks by file/module rather than by feature in the same file.
Verified: 5 concurrent agents (3 Codex + 2 agy), one file pair each → ~55s wall time, zero merge conflicts, no rate-limit errors. Two agents appending to the same file → conflict every time.

### Parallel waves (running a writing-plans plan)

After the pre-flight scan, run `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/waves.py <plan.md>` (`--json` for machine output) and paste its `| Wave | Tasks | Waits for |` table into the ledger without asking the user. It reads each task's `**Files:**` and `**Interfaces:**` blocks: tasks sharing a written file, or where one Consumes what an earlier one Produces (or says `(Task N)`), go in later waves. A task with no Files block waits for all earlier tasks, and all later tasks wait for it. Waves have at most 5 tasks.

Per wave:
1. BASE = the feature-branch head at wave start. One worktree and one implementer per task, dispatched in parallel with `WAVE=<N>` on each `run-agent.sh` call (the dashboard shows a `wave N` tag).
2. Reviewers run in parallel, one per task, each with its own fix loop (same caps as subagent-driven-development).
3. When every task in the wave is done, merge the task branches into the feature branch one at a time, running the suite after each merge. Write per-task ledger lines as usual, then `Wave N: merged (<commits>)`.
4. A stuck task (fix-loop cap hit) goes through the breaker; its wave-mates still merge. Tasks that depend on it wait, and you rule on them per the breaker rules.
5. A merge conflict despite the waves means the plan under-declared its files: resolve it yourself and add a LESSONS entry.

**Override:** when dispatching through delegate-agents with one worktree per task, tasks in the same wave may run in parallel. This overrides subagent-driven-development's "never dispatch multiple implementation subagents in parallel" for this case only; its ledger, briefs, per-task review, fix-loop caps and final review still apply.

**Plan authors (writing-plans):** keep writing `(Task N)` in a task's Consumes line — it is the most reliable dependency signal for `waves.py`.

## Choosing the shape: flat, two-level, or mixed (decide per run)

Decide each time from the plan in front of you; never default to two-level.

| Observable in the plan | Shape |
|---|---|
| ≤ ~8 tasks, or tasks share files/modules | **Flat**: you → workers (faster: 55s vs 115s for the same work in tests) |
| One module has a cluster of > ~3 tasks that only touch that module, the rest are few/small | **Mixed**: one sub-orchestrator for that cluster, other tasks straight to workers from you |
| Several independent modules, each with > ~3 tasks, or worker results would overflow your context | **Two-level**: one sub-orchestrator per module |
| A single task, or a quick review | No worktree, no sub-orchestrator: one worker call |

Re-decide when the plan changes (new tasks, a module turns out to be shared). The dashboard shows any mix: direct workers sit under "orchestrator", sub-orchestrators show their own children.

Two-level / mixed steps:
1. One area branch + worktree per area (`../wt-<area>`), split by module.
2. Sub-orchestrator per area: `cd ../wt-<area> && timeout 1500 claude -p "<area brief; read this SKILL.md; base branch <area>; task worktrees ../wt-<area>-<task>; don't touch master>" --model sonnet --effort medium --permission-mode acceptEdits --allowedTools "Bash(git:*)" "Bash(codex:*)" "Bash(agy:*)" "Bash(timeout:*)" "Bash(python3:*)" "Read"`, all areas in parallel.
3. Sub-orchestrators can't `cd` (blocked in headless): tell them to use `codex -C <abs path>` and `agy --add-dir <abs path>` with absolute paths.
4. You: run each area branch's tests, merge area branches one at a time, test, remove area worktrees.
Verified: 2 areas × 2 tasks (Codex + agy) → 115s, 0 conflicts, 38 tests passing after the top-level merge.

## Common mistakes

- Building a worker prompt with `sed` substitution or `$(python -c "...")` breaks on `|`, backticks, and quotes (seen twice: an empty prompt and a lost command). Write the prompt to a file with a quoted heredoc (`<<'EOF'`) and pass `"$(cat file)"`. `run-agent.sh` refuses empty prompts.

- Codex launched in background without `</dev/null` → prints "Reading additional input from stdin" and hangs until timeout. run-agent.sh handles it.

- Calling a worker without `-m/--model` and effort → runs whatever the config default is today.

- `codex exec --full-auto` → removed flag, prints usage. Use `-s workspace-write`.
- Checking `$?` after a pipe (`git merge ... | tail`) → reports tail's exit, hides the conflict. Check `git status` for `UU`.
- Omitting `timeout`/background for agy → can hang the turn.
- Delegating vague tasks → agent invents scope. Put the acceptance test in the prompt.
