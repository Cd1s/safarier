---
name: safarier-browser
description: Control Safarier browser profiles through its local CLI for authorized browsing, form testing, snapshots, screenshots and human-assisted workflows. Use when a task needs Safarier profile storage or proxy isolation.
---

# Safarier browser automation

Use the installed executable, even when `safarier` is absent from PATH:

```sh
SF=/Applications/Safarier.app/Contents/MacOS/Safarier
"$SF" agent spaces
```

In interactive shells, `alias safarier='/Applications/Safarier.app/Contents/MacOS/Safarier'` is optional. For a custom installation, use that app's executable path instead. CLI syntax below assumes the `SF` variable above.

## Workflow

1. Choose an existing profile by UUID or exact name. Open it without taking foreground focus:
   ```sh
   "$SF" agent open "Test Space" https://example.com --background
   "$SF" agent snapshot "Test Space"
   ```
2. Read the snapshot. Each visible interactive element has an `eN` reference, viewport center `@(x,y widthxheight)`, and relevant value/checked/disabled state. Password values are redacted. Offscreen coordinates are marked; scroll and take another snapshot before using them. References last until a new snapshot or document replacement; take a fresh snapshot after navigation or structural changes.
3. Fill controlled forms or type through segmented inputs:
   ```sh
   "$SF" agent fill "Test Space" e1 user@example.com
   "$SF" agent click "Test Space" e2
   "$SF" agent wait "Test Space" 'input[autocomplete="one-time-code"]'
   "$SF" agent type "Test Space" 'input[autocomplete="one-time-code"]' 123456 --delay-ms 30
   ```
   Use an OTP supplied by the user or an authorized test fixture. `type` follows the active element on each character, including auto-advancing single-character inputs. `fill` uses native value setters and beforeinput/input/change events; `beforeinput` cancellation is honored. Site-specific controls may still need their own interaction flow.
4. Re-snapshot and verify the result before a consequential action. A successful command means the interaction was dispatched, not that an account was created or a transaction completed.

## Batch execution

```sh
"$SF" agent eval "Test Space" '
  safarier.fill("#email", "user@example.com");
  safarier.click("button[type=submit]");
  await safarier.waitFor("#confirmation", 10000);
  return { text: safarier.text("#confirmation"), snapshot: safarier.snapshot() };
'
```

Scripts run in an isolated WebKit client world; `safarier` does not become a page-global object. This shares the DOM, not page JS variables or framework internals. DOM operations are scoped to the top document; cross-origin frame DOM remains inaccessible. `eval` is asynchronous, returns JSON, and uses the CLI's 15-second response deadline. Keep batches bounded; use `wait` with `--timeout-ms` (maximum 60000) for longer conditions. After a timeout inspect state before retrying: earlier steps may have completed.

Helpers:

- `safarier.snapshot()` refreshes refs and returns `{title,url,textSummary,elements,formatted}`.
- `safarier.click(target)` scrolls, focuses and invokes a DOM click.
- `safarier.fill(target,value)` fills input, textarea, select or contenteditable.
- `await safarier.type(target,text,delayMs=30)` types using the current focused field for every character.
- `await safarier.waitFor(selectorOrText,timeoutMs=10000)` waits for a visible CSS match, current ref or text substring. Prefer precise CSS selectors to ambiguous text.
- `await safarier.wait(msOrSelector)` sleeps or waits for a selector.
- `safarier.press(key)` dispatches DOM keyboard events; it does not implement OS shortcuts or browser default editing.
- `safarier.text([selector])` extracts rendered text.

Targets accept `e1`, `[e1]`, `[ref=e1]` or CSS selectors. DOM helper events are synthetic. `type` is not OS keyboard input or a human-behavior simulation.

## Coordinates, screenshots and human handoff

```sh
"$SF" agent screenshot "Test Space" /tmp/page.png
"$SF" agent click-xy "Test Space" 240 380 --tab 1
"$SF" agent focus "Test Space" --tab 1
```

`click-xy` dispatches native AppKit mouse events to the visible web viewport, in CSS viewport pixels from its top-left corner (page zoom is accounted for). Use a fresh snapshot/screenshot; coordinates change after scrolling, zooming, resizing or navigation. It can target ordinary canvas controls and frame surfaces without reading frame DOM. Native dispatch is not a guarantee that a site accepts an action.

If a CAPTCHA, passkey confirmation, consent prompt or other human-verification step appears, use `focus`, ask the user to complete it, then inspect the result. Do not solve or bypass CAPTCHA challenges, impersonate a human, or promise an undetectable browser. Profile isolation and Skill availability do not grant permission for external actions.

## Tabs and installation

```sh
"$SF" agent tab-list "Test Space"
"$SF" agent tab-new "Test Space" https://example.org
"$SF" agent tab-close "Test Space" --tab 2
"$SF" agent install-skill
"$SF" agent skill
```

Commands accepting `--tab N` use 1-based indices; re-list after closing a tab. Different profiles can run concurrently; serialize dependent commands within a tab. Local sockets are owner-only (directory 0700, socket 0600); processes under the same macOS account can control that profile. Snapshots and screenshots may contain personal information. Avoid embedding secrets in shell history or persisted logs.

Opening the Safarier manager synchronizes this guide to `.claude/skills`, `.claude-ifrr/skills` and `.agents/skills` under the user's home directory. Restart or reload your agent's skill discovery if needed. Other clients, including Cursor and OpenCode, may require importing the guide through their own supported configuration.

[safarier:skill] end of guide
