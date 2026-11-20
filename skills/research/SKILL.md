---
name: research
description: Use when delegate-agents starts work on new functionality and needs to know what already exists (repos, templates, libraries, services) before an implementation plan is written.
---

# Research phase

Before building anything new, a research worker finds what already exists (repos, templates, libraries,
services) so nothing is rewritten from scratch. The user reads the report and chooses; only then is an
implementation plan written. You (orchestrator) never search the web yourself and never choose for the user.

## 1. Clarify

Your first reply to a build request is one clarifying question, using superpowers:brainstorming's questioning:
one question per message, play back what you heard, until scope is clear (who uses it, must-haves, stack or
hosting limits, budget for paid services). No research plan, search or dispatch before scope is clear.
End by writing the acceptance criteria (each must-have becomes one) as a numbered list in the user's words to
`<repo>/.agents/criteria/YYYY-MM-DD-<topic>.md`.

## 2. Research plan

Write it yourself; no approval needed. Save it as the top of the report file.

```
Topic: <topic>
Find: <bases/templates, libraries, services that cover the must-haves>
Criteria: <must-haves from Clarify> · licence · maintained (last release/commit) · stack fit
Where: GitHub, package registries, vendor sites, recent comparisons
```

## 3. Dispatch

One worker, with the command under "Verified research command", id `research-<topic>`. Start the dashboard
first as the main skill says. Write the prompt to `<repo>/.agents/research-<topic>/prompt.txt` with a quoted heredoc:

```
You are the researcher. Do not edit files. Search the web live; do not answer from memory.
<research plan>
Return ONLY a markdown table with these columns, one row per candidate (3-6 candidates):
candidate | kind (base / library / service / build-it-ourselves) | fit | stack | licence | maintained | risks | link
- link: a URL you actually opened. maintained: date of last release or commit (YYYY-MM-DD).
- risks: include copyleft licences (GPL/AGPL), paid tiers, lock-in, abandonment.
- Always add one row "Build it ourselves" (kind build-it-ourselves, link -).
After the table: one line "Recommendation: <candidate> — <reason>".
```

## 4. Verify

- Each link: `curl -sIL -m 30 -o /dev/null -w '%{http_code}' <url>`; retry a `000` once. Not 200 → drop the row,
  or keep it marked `DEAD LINK` if it is the recommendation.
- Every row has licence and maintained filled; a GPL/AGPL licence appears in risks. Fix gaps or mark `unknown`.

## 5. Report

Save to `<repo>/.agents/research/YYYY-MM-DD-<topic>.md`: research plan, verified table, recommendation +
reason, then an empty `## Decision` section. Show the user the table and the recommendation in chat.

## 6. Wait

Stop. Ask which candidate to use. Write their answer under `## Decision` (date + choice + any conditions).
"None of these" → back to Clarify to find what was missing; do not default to "build it ourselves".
Then return to delegate-agents "Start here".

## Verified research command

```bash
TIMEOUT=900 MODE=ro AGENTS_LOG=<abs repo>/.agents/status.jsonl bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh codex gpt-6-luna medium <abs repo> research-<topic> - "$(cat <abs repo>/.agents/research-<topic>/prompt.txt)"
```

Measured 2026-11-20 (codex-cli 0.170, agy 1.5.12), prompt "3 open-source e-commerce repos updated in 2026, with URLs and release dates":
| Vendor | Time | URLs resolving | Dates after model cutoff | Live search evidence |
|---|---|---|---|---|
| Codex `gpt-6-luna` medium, `MODE=ro` | 50s | 6/6 | yes (2026-11-12 … 11-17) | 8 `web_search` events in `.agents/<id>/raw.jsonl` |
| agy `gemini-3.8-flash-high`, `MODE=ro` | 100s | 6/6 | yes (2026-11-17 … 11-19) | `search_web` tool calls in raw log |

- `MODE=ro` does not block web search for either vendor. Codex is the default (half the time); agy is the fallback.
- A curl `000` is usually a transient network error: retry once before marking a link dead (seen on 2 of 12 links, both 200 on retry).
