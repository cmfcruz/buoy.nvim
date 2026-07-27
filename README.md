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

- **The official agent TUI, docked in Neovim.** Run Claude Code or Codex in a
  split or float that stays anchored beside your code — no chat UI to maintain.
- **Context on every prompt.** A prompt hook automatically attaches the current
  file, cursor, visual selection, and open buffers to what you send — no tool
  call, no extra round trip.
- **The agent reads back.** buoy's private CLI lets the agent pull targeted
  buffer ranges and diagnostics, or move your cursor to a resolved location,
  mid-turn.
- **Layout that adapts.** Auto-picks a right-side split while there is room, a
  floating overlay once the editor gets narrow, and follows editor resizes.
  Either layout can be pinned explicitly.

## Requirements

- Neovim 0.11+ (required for exact visual-selection capture)
- The Codex and/or Claude Code CLI on your `$PATH`

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

Start Neovim, open any file, and **press `<F2>`** — the selected agent's TUI
opens beside the editor. (buoy auto-detects which agent CLI is on your `$PATH`,
preferring Claude Code; no config file required.)

On Windows, the terminal UI works normally, but buoy does not attach the POSIX
prompt hook or live editor CLI. Buoy warns once when the agent starts.

To update buoy later, pull the clone:

```sh
git -C ~/.local/share/nvim/site/pack/buoy/start/buoy.nvim pull
```

On Linux and macOS, the agent's view of your live editor state needs no extra
setup — it is configured at launch; see
[Per-prompt context enrichment](#per-prompt-context-enrichment) and
[Live editor bridge](#live-editor-bridge) for how it works.

## Configuration

buoy works with zero configuration: it auto-detects your agent CLI (Claude
Code first, then Codex) and maps `<F2>`. Call `setup()` only to override a
default — put it in your `init.lua` (`~/.config/nvim/init.lua`, or
`~/AppData/Local/nvim/init.lua` on Windows):

```lua
require("buoy").setup({
  agent = "codex",            -- pin the agent: "auto" (default) | "claude" | "codex"
  keymaps = {
    primary = "<F2>",         -- focus in a vsplit, show/hide in a float; false to disable
    secondary = "<S-F2>",     -- show/hide in a vsplit, focus in a float; false to disable
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
    expose_editor_context = true, -- attach the per-prompt editor snapshot + selection handoff
  },
})
```

- **Switch to Codex:** set `agent = "codex"`. (With the default `"auto"`,
  buoy uses Codex anyway if it's the only CLI on your `$PATH`.)
- **Override per session:** set the `BUOY_AGENT` environment variable
  (e.g. `BUOY_AGENT=codex nvim`) — it takes precedence over the `agent`
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
  Hiding never kills the agent session. If your terminal emulator doesn't
  deliver `<S-F2>`, set `keymaps.secondary` to another key; either mapping can
  also be `false`. `:BuoyToggle` shows or hides the window, while `:Buoy` opens
  or focuses it.
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
  per-prompt editor snapshot and the visual-selection handoff. A disabled
  capability is both omitted from the agent's instructions and refused if called.
  Turn all three off to disable buoy's buffer-content, diagnostic, and per-prompt
  context surfaces. This is a capability/privacy control, not a security boundary
  — a hosted agent can still read files through its own tools. Cursor navigation
  (`set_cursor_position`) is always available; when invoked, it returns navigation
  metadata including the destination's absolute path and final cursor position,
  but not file contents.
- Every key is optional; anything you omit keeps its default.

## Per-prompt context enrichment

On Linux and macOS, buoy registers a `UserPromptSubmit` hook
(`bridge/context_hook.lua`) with both agents: before the model sees each prompt,
the hook prints a focused snapshot of your editor state — cwd, current file,
cursor, visual selection, and open buffers — which the agent attaches as
context. Enrichment is deterministic (there is no tool call for the model to
skip) and costs no extra inference round trip.

For Claude Code the hook rides in an inline `--settings` JSON. For Codex it is
a session-scoped `-c hooks.UserPromptSubmit=...` override. Codex requires you
to review and trust the hook definition before it can run, then remembers that
trust while the definition stays unchanged.

If the hook cannot reach your Neovim it prints nothing and never blocks the
prompt.

## Live editor bridge

```
┌─ Neovim ──────────────────────┬─ Agent (official TUI) ─┐
│  editing buffers              │  › what does this      │
│  autocmds cache:              │    selection do?       │
│   file / cursor / selection   │                        │
│        ▲                      │  [context_hook enriches│
│        │ msgpack-RPC          │   every prompt with the│
│  ┌─────┴──────────────┐       │   private agent CLI    │
│  │ context_hook /     │       │   widen context        │
│  │ agent_cli          │◄──────┤   mid-turn]            │
│  └────────────────────┘       │                        │
│      (spawned by the agent)   │                        │
└───────────────────────────────┴────────────────────────┘
```

On Linux and macOS, buoy gives the agent a compact command prefix for its
private `bridge/agent_cli.lua` adapter. The agent invokes it through its normal
shell tool when it needs a live buffer range, diagnostics, or an explicitly
requested cursor jump. The CLI connects only to the Neovim session that
launched the terminal, returns one bounded JSON object, and follows the agent's
normal shell approval policy. It is an internal integration surface, not a
globally installed user command.

## Agent instructions

buoy automatically adds its Neovim context guidance when it launches the
agent. For Claude Code it uses `--append-system-prompt`. For Codex, buoy first
asks `codex app-server` for the effective `developer_instructions` at Neovim's
working directory, then appends its guidance without changing Codex's normal
configuration precedence.

If the Codex configuration cannot be resolved within two seconds, buoy shows a
warning and launches Codex without a developer-instructions override. This
preserves the instructions Codex would normally load instead of replacing them
with incomplete context. The prompt hook remains active, but on-demand live
operations are unavailable for that session; buoy does not retry configuration
resolution.

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

- On Linux and macOS, editor context refreshes when you submit a prompt and
  when the agent invokes the private CLI; buoy does not stream
  selection-changed events continuously.
- Windows supports the terminal UI but not the prompt hook or live editor CLI.
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
