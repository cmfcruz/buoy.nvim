# buoy.nvim

[![Release](https://img.shields.io/github/v/release/cmfcruz/buoy.nvim?label=release)](https://github.com/cmfcruz/buoy.nvim/releases)
[![License](https://img.shields.io/github/license/cmfcruz/buoy.nvim)](LICENSE)
![Neovim](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)
![Lua](https://img.shields.io/badge/Lua-5.1%2B-2C2D72?logo=lua&logoColor=white)

<p align="center">
  <img src="docs/buoy.png" alt="buoy.nvim" width="400">
</p>

> Floats or docks — stays anchored to the code.

A dedicated Neovim window for Claude Code or Codex, with live editor context on
every prompt.

<p align="center">
  <img src="docs/demo.gif" alt="buoy.nvim docked beside a Neovim buffer with an agent mid-turn" width="900">
</p>

- **The official agent TUI, docked in Neovim.** Run Claude Code, Codex, or Pi in a
  split or float that stays anchored beside your code — no chat UI to maintain.
- **Context on every prompt.** A prompt hook automatically attaches the current
  file, cursor, visual selection, and open buffers to what you send — no tool
  call, no extra round trip.
- **Buffers follow agent edits.** After a native `Edit` or `Write` tool call,
  buoy checks for external file changes so clean buffers refresh without
  overwriting unsaved edits.
- **The agent reads back.** buoy's private CLI lets the agent pull targeted
  buffer ranges and diagnostics, or move your cursor to a resolved location,
  mid-turn.
- **Layout that adapts.** Auto-picks a right-side split while there is room, a
  floating overlay once the editor gets narrow, and follows editor resizes.
  Either layout can be pinned explicitly.

## Requirements

- Neovim 0.11+ (required for exact visual-selection capture)
- The Claude Code, Codex, and/or Pi CLI on your `$PATH`

## Install

buoy.nvim runs inside Neovim, so installing it means cloning it where Neovim
looks. Neovim loads anything in its built-in `pack/*/start/` folder
automatically at startup, and buoy configures itself with sensible defaults on
first load. On Linux and macOS, the clone is the only step: buoy enriches every
prompt with live editor state and attaches its private CLI when it launches the
agent (see [Live editor bridge](#live-editor-bridge)).

**Linux/macOS:**

```sh
git clone https://github.com/cmfcruz/buoy.nvim \
  ~/.local/share/nvim/site/pack/buoy/start/buoy.nvim
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/cmfcruz/buoy.nvim `
  "$env:LOCALAPPDATA\nvim-data\site\pack\buoy\start\buoy.nvim"
```

Start Neovim and buoy opens the selected agent's TUI automatically while
leaving your editor, file explorer, dashboard, or other startup window focused.
A startup reminder shows the layout-aware shortcuts (by default `<F2>` and
`<S-F2>`). Buoy auto-detects which agent CLI is on your `$PATH`, preferring
Claude Code, then Codex, then Pi; no config file is required.

On Windows, the terminal UI works normally, but buoy does not attach its POSIX
bridge hooks or live editor CLI. Buoy warns once when the agent starts.

To update buoy later, pull the clone:

```sh
git -C ~/.local/share/nvim/site/pack/buoy/start/buoy.nvim pull
```

On Linux and macOS, the agent's view of your live editor state needs no extra
setup — it is configured at launch; see
[Automatic editor hooks](#automatic-editor-hooks) and
[Live editor bridge](#live-editor-bridge) for how it works.

## Configuration

buoy works with zero configuration: it auto-detects your agent CLI (Claude
Code first, then Codex, then Pi), opens it after startup, and maps `<F2>`. Call
`setup()` only to override a default — put it in your `init.lua` (`~/.config/nvim/init.lua`, or
`~/AppData/Local/nvim/init.lua` on Windows):

```lua
require("buoy").setup({
  agent = "codex",            -- pin the agent: "auto" (default) | "claude" | "codex" | "pi"
  keymaps = {
    primary = "<F2>",         -- focus in a vsplit, show/hide in a float; false to disable
    secondary = "<S-F2>",     -- show/hide in a vsplit, focus in a float; false to disable
  },
  startup = {
    open = true,              -- false restores manual-open startup behavior
    message = true,           -- false suppresses the startup shortcut reminder
  },
  -- cmd = "codex",           -- override the agent binary if it isn't on $PATH by name
  window = {
    style = "auto",           -- "auto" (default) | "vsplit" | "float"
    width = 80,               -- fixed columns of text for the agent (integer, minimum 40)
    border = "rounded",       -- used by the floating window
    stay = false,             -- keep the agent split open after all other windows close
  },
  context = {
    expose_buffers = true,        -- let the agent read live buffer contents (get_buffer_range)
    expose_diagnostics = true,    -- let the agent read buffer diagnostics (get_diagnostics)
    expose_editor_context = true, -- prompt snapshot + selection handoff
                                  -- and post-tool buffer refresh
  },
})
```

- **Startup behavior:** buoy opens one agent window automatically and then
  returns focus to the startup window that was active before it opened. Set
  `startup.open = false` to launch only on demand, or
  `startup.message = false` to keep automatic opening without the startup
  reminder. The reminder uses your configured key notation, omits disabled
  mappings, and describes the actions for the split or float that actually
  opened. It is dismissed by the first configured Buoy keypress or replaced
  naturally by the next command or message.
- **Switch agents:** set `agent = "codex"` or `agent = "pi"`. (With the default
  `"auto"`, buoy uses Pi too if it's the only supported CLI on your `$PATH`.)
- **Override per session:** set the `BUOY_AGENT` environment variable
  (e.g. `BUOY_AGENT=pi nvim`) — it takes precedence over the `agent`
  configured in `setup()`.
- **Config applies at startup:** buoy initializes once per Neovim session —
  the first `setup()` (or the zero-config defaults, shortly after startup)
  wins, and later calls only warn. Call `setup()` during startup rather than
  from a deferred hook, edit + restart Neovim to change the configuration,
  and use `BUOY_AGENT` for a one-off agent switch.
- **Layout-aware keys:** the two mappings are named by role — `primary` and
  `secondary` — rather than by action, because the action each performs depends
  on the agent's layout. The primary key is always the one you reach for: in a
  `vsplit` the agent is always visible, so it just moves focus; in a `float` it
  overlaps your code, so it shows/hides the window instead. The secondary key
  does the other. When the agent is closed, the layout it *would* open into
  decides.
  - **Primary — `<F2>` (`keymaps.primary`):** focus-switch between the terminal
    and your last window in a `vsplit`; show/hide the window in a `float`. Opens
    the agent when it's closed.
  - **Secondary — `<S-F2>` (`keymaps.secondary`):** the other action — show/hide
    in a `vsplit`, focus-switch in a `float`.
  Hiding never kills the agent session. For secondary mappings from `<S-F1>`
  through `<S-F12>`, buoy also maps the traditional terminfo alias `<F13>`
  through `<F24>`; for example, `<S-F2>` also listens on `<F14>`. These aliases
  are global mappings, so they can replace an existing mapping for the same key
  if buoy is configured later. If pressing Shift+F2 produces no input in Neovim
  because your OS or terminal reserves it, configure another secondary key.
  Either mapping can also be `false`. `:BuoyToggle` shows or hides the window,
  while `:Buoy` opens or focuses it.
- **Window layout:** `"auto"` (default) chooses a right-side `vsplit` while
  every code window would stay wider than `window.width`, otherwise a `float`
  overlay so your code is never squeezed below the agent's own width. The
  decision reads the actual window layout, not just the editor width: a tab
  already divided into columns floats where a tab holding one full-width buffer
  splits, and horizontal splits still get a `vsplit` because they keep their
  full width. Set `window.style` to `"vsplit"` or `"float"` to pin one.
  `window.width` is a fixed column count applied to both layouts (clamped to fit
  a narrow editor); it must be an integer of at least 40, and `setup()` raises a
  configuration error otherwise. `window.border` applies only to the floating
  window. While the agent is open, resizing the editor keeps it in step: an
  `"auto"` window flips between split and float as it crosses the width boundary
  — reusing the running agent session — and a float stays anchored to the
  resized editor. The split holds its column count against `<C-w>=` and new
  splits (it sets `winfixwidth`), and rearranging your own windows never
  relayouts the agent; the layout is chosen when it opens and re-evaluated when
  the editor resizes.
- **Close with the last window:** by default buoy quits the agent split once it
  is the last ordinary window in its tabpage — on the final tab, that quits
  Neovim, mirroring file-tree plugins like neo-tree, so a `vsplit` agent window
  never lingers after you close your other windows. Set `window.stay = true` to
  keep it open instead; if you then hide an agent that has outlived every other
  window, buoy restores an ordinary window beside it first, so hiding always
  hides. Floats are unaffected (they never strand an ordinary window).
- **Limit what the agent sees:** the `context` switches gate buoy's
  agent-facing surfaces, all enabled by default. Set `expose_buffers = false` to
  disable `get_buffer_range` (live buffer contents), `expose_diagnostics = false`
  to disable `get_diagnostics`, and `expose_editor_context = false` to drop the
  per-prompt editor snapshot, visual-selection handoff, and post-tool buffer
  refresh. A disabled read capability is both omitted from the agent's
  instructions and refused if called. Turn all three off to disable buoy's
  buffer-content, diagnostic, and automatic editor-hook surfaces. This is a
  capability/privacy control, not a security boundary — a hosted agent can still
  read files through its own tools. Cursor navigation (`set_cursor_position`) is
  always available; when invoked, it returns navigation metadata including the
  destination's absolute path and final cursor position, but not file contents.
- Every key is optional; anything you omit keeps its default.

## Automatic editor hooks

On Linux and macOS, buoy registers its unified `bridge/buoy.lua` CLI in
`hook-context` mode with each supported agent. Before the model sees each
prompt, the hook prints a focused snapshot of your editor state — cwd, current
file, cursor, visual selection, and open buffers — which the agent attaches as
context. Enrichment is deterministic (there is no tool call for the model to
skip) and costs no extra inference round trip.

Buoy registers the same CLI in `hook-checktime` mode as a `PostToolUse` hook for
the agents' native `Edit` and `Write` tools. After either tool completes, the
hook runs `:checktime` in the launching Neovim so clean, externally changed
buffers refresh under Neovim's normal `autoread` behavior. Buffers with unsaved
edits are never overwritten; Neovim keeps its normal warning and reload-choice
behavior. Writes performed through shell commands do not trigger this hook.

Hook wiring is agent-specific:

- **Claude Code:** hooks ride in an inline `--settings` JSON.
- **Codex:** hooks are session-scoped `-c hooks.UserPromptSubmit=...` and
  `-c hooks.PostToolUse=...` overrides. Codex requires you to review and trust
  each hook definition before it can run, then remembers that trust while the
  definitions stay unchanged.
- **Pi:** buoy loads a bundled `--extension` that injects the prompt snapshot
  from `before_agent_start` and refreshes buffers from `tool_result` after Pi's
  native `edit` or `write` tools.

If either hook cannot reach your Neovim, it silently does nothing and never
blocks the agent.

## Live editor bridge

```
┌─ Neovim ──────────────────────┬─ Agent (official TUI) ─┐
│  editing buffers              │  › what does this      │
│  autocmds cache:              │    selection do?       │
│   file / cursor / selection   │                        │
│        ▲                      │                        │
│        │ Neovim RPC           │                        │
│  ┌─────┴──────────────┐       │                        │
│  │ buoy CLI           │◄──────┤  snapshot each prompt  │
│  │                    │◄──────┤  PostToolUse Edit/Write│
│  │                    │◄──────┤  on-demand operations  │
│  └────────────────────┘       │                        │
│  (spawned by the agent)       │                        │
└───────────────────────────────┴────────────────────────┘
```

On Linux and macOS, buoy gives the agent a compact command prefix for its
private `bridge/buoy.lua` CLI. The same entry point serves lifecycle hooks and
on-demand operations, so it is the only bridge script agents need to invoke.
The agent runs it through its normal shell tool when it needs a live buffer
range, diagnostics, or an explicitly requested cursor jump. The CLI connects
only to the Neovim session that launched the terminal, returns one bounded JSON
object, and follows the agent's normal shell approval policy. It is an internal
integration surface, not a
globally installed user command.

## Agent instructions

buoy automatically adds its Neovim context guidance when it launches the
agent. For Claude Code it uses `--append-system-prompt`. For Codex, buoy first
asks `codex app-server` for the effective `developer_instructions` at Neovim's
working directory, then appends its guidance without changing Codex's normal
configuration precedence. For Pi, the bundled extension appends buoy's guidance
to Pi's assembled system prompt, preserving discovered `APPEND_SYSTEM.md`
instructions.

If the Codex configuration cannot be resolved within two seconds, buoy shows a
warning and launches Codex without a developer-instructions override. This
preserves the instructions Codex would normally load instead of replacing them
with incomplete context. Both automatic hooks remain active, but on-demand
live operations are unavailable for that session; buoy does not retry
configuration resolution.

## Usage

1. `<F2>` opens the window. Once it's open the keys are layout-aware: in a
   `vsplit`, `<F2>` switches focus between the agent and your code while `<S-F2>`
   shows/hides the window; in a `float` those swap, so `<F2>` shows/hides and
   `<S-F2>` switches focus. `:Buoy` always opens or focuses the agent and
   `:BuoyToggle` always shows or hides it; the agent session survives hiding.
2. Edit normally, select code in visual mode, then bring up the agent from the
   selection with `:Buoy` (or the focus key for your layout). Both preserve the
   handoff selection, so the next prompt automatically carries its range and
   text.

## Limitations / roadmap

- On Linux and macOS, editor context refreshes when you submit a prompt,
  externally changed buffers are checked after native `Edit` and `Write` tool
  calls, and the private CLI reads live state on demand. Shell-based writes do
  not trigger post-tool refresh, and buoy does not stream selection-changed
  events continuously.
- Windows supports the terminal UI but not the bridge hooks or live editor CLI.
- `open_diff` / in-editor approval is intentionally out of scope: the
  official TUI already renders diffs and approvals, which is the point.

## Development

Contributions go through pull requests; `main` is protected by CI.

- **Tests** — run every headless spec with:

  ```sh
  for spec in tests/*_spec.lua; do
    nvim --headless -u NONE -i NONE -l "$spec"
  done
  ```

- **Formatting** — [StyLua](https://github.com/JohnnyMorganz/StyLua).
  Run `stylua .` (or `stylua --check .` to verify).
- **Linting** — [Selene](https://github.com/Kampfkarren/selene). Run
  `selene .`. The Neovim runtime is described in `vim.yml`.
- **Pre-commit** — `pip install pre-commit && pre-commit install` wires
  StyLua and a few hygiene hooks into your commits (StyLua's binary is
  fetched automatically; install Selene separately if you want it locally).

CI (`.github/workflows/ci.yml`) runs the tests, formatting check, and lint on
every PR.

### Releases

Versioning is automated with
[Release Please](https://github.com/googleapis/release-please) using
[Conventional Commits](https://www.conventionalcommits.org/). Merging
`feat:` / `fix:` commits to `main` opens a release PR that bumps
`version.txt`, updates the changelog, and — once merged — tags the
release. Use `feat:`/`fix:` in commit subjects (and `feat!:` or a
`BREAKING CHANGE:` footer for breaking changes).
