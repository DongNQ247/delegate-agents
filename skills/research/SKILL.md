---
name: research
description: Use when delegate-agents starts work on new functionality and needs to know what already exists (repos, templates, libraries, services) before an implementation plan is written.
---

# Research phase

## Verified research command

```bash
TIMEOUT=900 MODE=ro AGENTS_LOG=<abs repo>/.agents/status.jsonl bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh codex gpt-6-luna medium <abs repo> research-<topic> - "$(cat <prompt file>)"
```

Measured 2026-11-20 (codex-cli 0.170, agy 1.5.12), prompt "3 open-source e-commerce repos updated in 2026, with URLs and release dates":
| Vendor | Time | URLs resolving | Dates after model cutoff | Live search evidence |
|---|---|---|---|---|
| Codex `gpt-6-luna` medium, `MODE=ro` | 50s | 6/6 | yes (2026-11-12 … 11-17) | 8 `web_search` events in `.agents/<id>.raw.jsonl` |
| agy `gemini-3.8-flash-high`, `MODE=ro` | 100s | 6/6 | yes (2026-11-17 … 11-19) | `search_web` tool calls in raw log |

- `MODE=ro` does not block web search for either vendor. Codex is the default (half the time); agy is the fallback.
- A curl `000` is usually a transient network error: retry once before marking a link dead (seen on 2 of 12 links, both 200 on retry).
