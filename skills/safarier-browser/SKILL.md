---
name: safarier-browser
description: Drive Safarier isolated browser spaces (profiles) from AI agents via the local `safarier agent` CLI bridge without stealing foreground focus or polluting page JavaScript globals.
---

# Safarier Browser Agent Skill (`safarier agent`)

Safarier provides a native macOS WebKit browser where every Profile ("Space") has an isolated website data store, independent proxy / sing-box outbound tunnel, native Safari anti-fingerprinting protections, and a local Unix Domain Socket bridge for AI agents.

All DOM queries and code-based interactions run inside `WKContentWorld.defaultClient` (isolated from page scripts) and `--background` launches never steal window focus from the human user.

## Quick Start Workflow

1. **List available spaces (profiles) and running status:**
   ```sh
   safarier agent spaces
   ```

2. **Open a URL in a space (auto-launches in background if not running):**
   ```sh
   safarier agent open <PROFILE_ID_OR_NAME> https://example.com --background
   ```

3. **Take a structured DOM snapshot with interactive element refs (`e1`, `e2`, ...):**
   ```sh
   safarier agent snapshot <PROFILE_ID_OR_NAME>
   ```

4. **Interact using element refs (`e1`) or CSS selectors:**
   ```sh
   safarier agent fill <PROFILE_ID_OR_NAME> e1 "user@example.com"
   safarier agent click <PROFILE_ID_OR_NAME> e2
   ```

5. **Code-based multi-step execution (`eval`):**
   Batch multiple actions in one round-trip using the built-in `safarier` helper in `.defaultClient`:
   ```sh
   safarier agent eval <PROFILE_ID_OR_NAME> '
     safarier.fill("e1", "hello");
     safarier.click("e2");
     await safarier.wait(200);
     return { title: document.title, text: safarier.text(), snap: safarier.snapshot() };
   '
   ```

6. **Capture a PNG screenshot (works in background without foregrounding the window):**
   ```sh
   safarier agent screenshot <PROFILE_ID_OR_NAME> /tmp/page.png
   ```

7. **Manage tabs inside a space:**
   ```sh
   safarier agent tab-list <PROFILE_ID_OR_NAME>
   safarier agent tab-new <PROFILE_ID_OR_NAME> https://example.org
   safarier agent tab-close <PROFILE_ID_OR_NAME> --tab 2
   ```

## Built-in `safarier` Helper API in `eval`

- `safarier.snapshot()` — Returns `{ title, url, textSummary, elements, formatted }` and refreshes `e1`, `e2`, ... refs.
- `safarier.click(target)` — Scrolls into view, focuses, and clicks `e1` ref or CSS selector.
- `safarier.fill(target, value)` — Focuses input/textarea/select, sets `.value`, and dispatches `input` + `change` events.
- `safarier.press(key)` — Dispatches `keydown`/`keypress`/`keyup` events on the active element.
- `safarier.wait(ms)` — Returns a Promise resolving after `ms` milliseconds.
- `safarier.text([selector])` — Returns trimmed text of the matching element (or `document.body` when omitted).

[safarier:skill] end of guide
