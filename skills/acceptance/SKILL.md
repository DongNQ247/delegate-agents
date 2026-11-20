---
name: acceptance
description: Use when delegate-agents has merged all tasks of a run and must check the result against its acceptance criteria before hand-off.
---

# Acceptance (Tester)

## Verified web route

Measured 2026-11-20 (agy 1.5.13, Playwright 1.63.0), static page with a button that changes a text on click:
| Route | Result |
|---|---|
| agy `gemini-3.8-flash-high`, `MODE=ro`, prompt "use your browser tools" | FAIL: `browser_*` tools are listed in the init event but none was called in 191s; it curled the page, then tried to drive Windows Chrome from WSL and ran `taskkill /F /IM chrome.exe`. Stopped. |
| Playwright script in Node with the cached Chromium | PASS in ~1s: text before/after click matched, screenshot written, console errors collected |

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
