---
name: acceptance
description: Use when delegate-agents has merged all tasks of a run and must check the result against its acceptance criteria before hand-off.
---

# Acceptance (Tester)

Runs once, after every task of the run is merged and the suite passes, before hand-off. A Tester worker checks the
merged product against the run's criteria, as a user would. You (orchestrator) never test it yourself.

## 1. Inputs

- Criteria: `<repo>/.agents/criteria/YYYY-MM-DD-<topic>.md` (numbered list, written at "Start here").
- How to run the product: the survey report's Conventions and `AGENTS.md`.

## 2. Pick recipe and vendor

| Project type | Tester does | Vendor |
|---|---|---|
| Web UI | you start the app and prepare Playwright (see "Verified web route"); the Tester drives it with a Node script: click/type per criterion, screenshot, console errors | Claude (`ALLOWED_TOOLS="Write,Bash(NODE_PATH=<tools>/node_modules node:*)"`) |
| CLI / script | run commands with real input, compare output and exit code | Codex, or Claude `MODE=ro` with `ALLOWED_TOOLS="Bash(<exact command prefix>:*)"` (tell it to run the command exactly in that form) |
| Library | short script using the public API as a user would | Codex |
| Other (desktop, ML…) | follow the run instructions in `AGENTS.md`; none → stop: "can't self-test", list manual steps for the user | — |

Use a vendor different from the one that wrote most of the code when possible (same rule as review): Claude for web; agy only for CLI/library checks (it must not drive browsers or host apps).
`MODE=ro`, unless the check must start a server or write a script/screenshot: then `MODE=rw` in a scratch worktree of the
merged branch, never the main tree. Id `test-<topic>`.

## 3. Tester prompt

Write it to a file with a quoted heredoc:

```
You are the Tester. Never edit project code or tests, and never change the criteria.
Product: <repo/worktree>. How to run it: <from survey Conventions / AGENTS.md>.
Criteria:
<numbered list>
Check every criterion on the running product, as a user would. If it needs a server: start it, wait until it answers,
stop it when done. Write any helper script and screenshot outside the repo, under <scratch dir>.
A criterion with no observable check (e.g. "fast enough"), or one you cannot run → BLOCKED, with the reason. Never PASS
without evidence.
Return ONLY a markdown table: # | criterion | PASS/FAIL/BLOCKED | evidence (command + output excerpt, or screenshot path)
```

## 4. Verify

Save the table to `<repo>/.agents/test/YYYY-MM-DD-<topic>.md`. Spot-check it: every row has evidence, cited files
exist, and rerun one PASS command yourself. A PASS without evidence counts as FAIL.

## 5. Fail loop (max 2 rounds)

1. Map each FAIL to the task that owns it (plan + `git log`).
2. `RESUME=<that worker's id>` with new id `<id>-acceptN`: only the failing criterion and its evidence.
3. Unit tests + cross-vendor review as usual; merge.
4. The Tester re-checks **all** criteria (a fix can break an earlier PASS): `RESUME=test-<topic>`, new id `test-<topic>-N`.

Still failing after round 2 → stop and report to the user: what failed, what was tried, evidence.

## 6. Stop and report (no auto-fix)

- A criterion is ambiguous or contradictory, or fixing it would change scope or design.
- The product can't be run or tested (missing data, accounts, no recipe), or any BLOCKED row.
- The cause is outside the new code (environment, external service).

## Keep the tests (only when the user asks)

The Tester's checks become E2E tests in the repo: a normal worker task with acceptance cases from the criteria,
then cross-vendor review. Never commit Tester scripts directly.

## Verified web route

Measured 2026-11-20 (agy 1.5.13, Playwright 1.63.0), static page with a button that changes a text on click:
| Route | Result |
|---|---|
| agy `gemini-3.8-flash-high`, `MODE=ro`, prompt "use your browser tools" | FAIL: `browser_*` tools are listed in the init event but none was called in 191s; it curled the page, then tried to drive Windows Chrome from WSL and ran `taskkill /F /IM chrome.exe`. Stopped. |
| Playwright script in Node with the cached Chromium | PASS in ~1s: text before/after click matched, screenshot written, console errors collected |

Measured 2026-11-20 in real runs:
- Codex's sandbox cannot bind a port or reach localhost (`PermissionError` on `http.server`), so it can't test a web app; use it for CLI/library checks.
- A bare `require('playwright')` fails unless the package is installed: you prepare it once per run with
  `npm i --prefix <scratch>/tools playwright@<version matching the cached Chromium>` (no browser download when the build is cached),
  start the server yourself, wait until it answers, dispatch the Tester, then stop the server.
- Claude Tester with that setup: 3/3 criteria checked with evidence + screenshot. With a too-narrow `ALLOWED_TOOLS`
  it correctly returned BLOCKED (never a false PASS).
- CLI loop verified end to end: FAIL → `RESUME` owning worker with the evidence → Tester `RESUME`d re-checked all → 3/3 PASS.

So web checks use Playwright, not agy browser tools. The Tester writes a short script outside the repo and runs it with
the Playwright package whose Chromium build is already in `~/.cache/ms-playwright` (pin the exact version; otherwise
`npx -y playwright@<version> install chromium` first). `npx -y playwright@<version> screenshot <url> <file>` works for a
page that needs no clicks (~4s). Script shape:

```js
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const p = await b.newPage();
  const errs = []; p.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await p.goto(process.argv[2]);
  await p.click('#go'); console.log(await p.textContent('#msg'));
  await p.screenshot({ path: 'shot.png' }); console.log(JSON.stringify(errs)); await b.close();
})();
```
