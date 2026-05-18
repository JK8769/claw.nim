# Dashboard architecture: how claw daemon talks to zen

## The four layers

```
        ┌────────────────────────────────────────────┐
        │              zen   (the browser)            │
        │   tabs, panes, event loop, app lifecycle    │
        └────┬─────────────────────────┬──────────────┘
             │ imports                  │ imports
             ▼                          ▼
        ┌─────────────┐         ┌────────────────────┐
        │     tui     │         │       ttml          │
        │ (renderer)  │ depends │  (spec — pure data) │
        │             │ ──────▶ │                     │
        │  Component, │         │  TtmlNode, parser,  │
        │  Canvas,    │         │  build DSL, swap    │
        │  layout,    │         │  semantics          │
        │  widgets,   │         │                     │
        │  terms      │         │                     │
        └─────────────┘         └─────────┬───────────┘
                                          │ imports (only)
                                          ▼
                                  ┌────────────────┐
                                  │  claw daemon   │
                                  │  (producer)    │
                                  └────────────────┘
```

claw's dashboard work happens at the bottom layer: emit TTML strings
that describe the dashboard; zen receives them, parses via ttml,
renders via tui. claw NEVER imports tui's renderer code.

## What claw imports

```nim
# src/claw/daemon_orch.nim

import ttml/[types, build]                    # the spec + DSL
import tui/spec/context_menu                  # one extension-tag shim
# ↑ that's literally all of the markup-stack imports claw needs
```

We can verify at the binary level that no rendering code is linked:

```sh
$ nimble build && nm ./claw | grep -ic 'tui_components'   # → 0
$ nm ./claw | grep -ic 'tui_runtime'                       # → 0
$ nm ./claw | grep -c  'tContextMenu'                      # → 1
```

claw is genuinely a "pure markup producer" — like an HTTP server
emitting HTML, never linking the browser.

## How a dashboard event flows

### Outbound: claw sending a swap to zen

```
1. User clicks "[+ New company]" in zen's 🦞 nimclaw tab.

2. zen routes the SGR mouse event through its event loop, finds the
   clickable Text component, reads its id="new-company".

3. zen emits a JSONL line over the UNIX socket to claw daemon:
       {"method":"click","target":"#new-company"}

4. claw's runZenLoop reads the line, dispatches handleZenClick:
       case id
       of "new-company":
         acquire(o.lock); defer: release(o.lock)
         o.showingTemplatePicker = true
         return zcrOk

5. The zcrOk return triggers two swap events back to zen:
       emitZen(zenContentSwap(orch))   # rerenders the Company tab
       emitZen(zenStatusSwap(orch))    # status bar (counts unchanged)

6. zenContentSwap builds a TtmlNode tree via the buildTtml DSL. Now
   showingTemplatePicker is true, so the tree includes:
       tContextMenu(items = listAvailableTemplates(),
                    idPrefix = "template-",
                    title = " Pick a template ")
   The serialize() walk produces a string like:
       <ContextMenu items="solar-power-station" id="template-picker"
                    idPrefix="template-" title=" Pick a template "/>

7. claw emits the JSONL:
       {"event":"swap","target":"#content","ttml":"<Box>…
        <ContextMenu items='…' idPrefix='template-' …/>…</Box>"}

8. zen reads the JSONL, calls TtmlWidget.applyUpdate("swap","#content",ttml):
   • parseDoc() builds a TtmlNode tree from the string
   • Registry.build() walks the tree; on the <ContextMenu> tag the
     registered factory expands it to a Box+Text composite
   • The composite splices into #content's children, replacing the
     old contents

9. zen's next frame redraws — the popup appears in the tab.
```

### Inbound: user picks a template

```
10. User clicks "solar-power-station" inside the popup.

11. zen hit-tests at (x, y), finds the Text whose id="template-solar-
    power-station" and has clickable="". It emits:
       {"method":"click","target":"#template-solar-power-station"}

12. claw's handleZenClick matches `id.startsWith("template-")`,
    extracts the template name, calls dispatchCreateFromTemplate:
       discard execShellCmd("claw co create --template … --as …")
    (Synchronous; blocks the event loop ~1–2s for template-based
    creates. The new company appears in scanCompanies() after.)

13. claw clears showingTemplatePicker, refreshes content + status.
    zen sees the new company in the list.
```

## Where each file in claw plugs in

| File | Role |
|---|---|
| `src/claw/daemon_orch.nim` | The dashboard. All TTML emission, all click dispatch, all state. Uses `buildTtml`, `tContextMenu`, etc. |
| `src/claw.nim` (CLI dispatch) | Not involved in the dashboard. Shells called by the daemon (e.g. `claw co create`) reach here via `execShellCmd`. |
| `res/providers.json`, `res/models.json` | Read by daemon at startup (also baked into binary via `staticRead` as fallback) to populate Provider + Model tabs. |
| `res/templates/*` | Discovered by daemon's `listAvailableTemplates()` for the `<ContextMenu>` picker. |

## Adding a new dashboard feature

Follow this rhythm:

1. **Decide what tag(s) to emit**. Use existing standard tags
   (`tBox`, `tText`, `tRule`, `tSpinner`, `tMarkdown`, `spc`) from
   `ttml/build` when possible. For extension tags (`tContextMenu`,
   future `tSelectList`, etc.) import the relevant `tui/spec/*` module.

2. **Add the tag's emission to the renderer fn**. The Company /
   Provider / Model / Setting tabs each have a `*Children(o)` proc
   returning `seq[TtmlNode]`. Use `buildTtmlSeq` to construct the
   tree from regular Nim control flow:

   ```nim
   buildTtmlSeq:
     Box(class = flexRow, h = 1):
       Text("Hello")
       spc(2)
       tContextMenu(items = …, idPrefix = "foo-")
   ```

3. **Wire the click handler**. Add a clause to `handleZenClick`:

   ```nim
   if id.startsWith("foo-"):
     let payload = id["foo-".len .. ^1]
     # do thing with payload
     return zcrOk
   ```

4. **Refresh emission**. The `runZenLoop` and `handleSocketSession`
   loops emit `zenContentSwap` / `zenStatusSwap` automatically after
   `zcrOk` — no further work needed unless you're triggering nav
   changes (`zcrTabChange` also swaps `#nav`).

5. **Test via MCP**. zen exposes a `dashboard_simulate` tool over its
   MCP socket; pipe `<your TTML>` and an action stream through it to
   verify the rendering before involving the live daemon.

6. **For extension tags zen doesn't know**: register the renderer in
   zen's `newDefaultRegistry` (in `zen/ui/ttml_widget.nim`) AND in
   `newFullRegistry` (in `zen/mcp/headless.nim`). Both must stay in
   sync.

## Reference docs

- [`ttml/ARCHITECTURE.md`](https://github.com/JK8769/ttml/blob/main/ARCHITECTURE.md)
  — the spec layer
- [`tui/ARCHITECTURE.md`](https://github.com/JK8769/tui/blob/main/ARCHITECTURE.md)
  — the renderer layer (when published; currently local-only)
- This document — how claw consumes both
