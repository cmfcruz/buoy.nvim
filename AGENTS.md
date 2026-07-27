# Repository Guidelines

## Project Structure & Module Organization

`buoy.nvim` is a Lua plugin for Neovim 0.11+. Runtime modules live in `lua/buoy/`: `init.lua`
owns one-shot setup, socket publication, and default keymaps; `terminal.lua` owns the agent
window and terminal job; `context.lua` caches editor state and visual handoffs; `tools.lua`
and `navigate.lua` implement live reads and cursor navigation; `capabilities.lua` is the
single source of truth for the `context` capability switches and `error.lua` builds the
shared error result. `launcher.lua`,
`instructions.lua`, `codex.lua`, and `codex_protocol.lua` build agent-specific launch
arguments and preserve Codex's effective instructions: `codex.lua` spawns the
`codex app-server` transport and `codex_protocol.lua` runs the JSON-RPC handshake that reads
Codex's `developer_instructions`. User commands and zero-configuration startup live in
`plugin/buoy.lua`.

Standalone scripts under `bridge/` provide the per-prompt context hook, private one-shot
agent CLI, and shared Neovim RPC discovery. There is no MCP server; the CLI exposes exactly
`get_buffer_range`, `get_diagnostics`, and `set_cursor_position`. Bridge children run with
`nvim --headless -u NONE -i NONE -l`. The live bridge is attached only on Linux and macOS;
Windows keeps the terminal UI without live editor context. Self-contained headless specs
live in `tests/`. Project-site media live under `docs/`, while `_config.yml` configures the
root-based GitHub Pages site that renders the README as its index. CI and release automation
live in `.github/workflows/`. Do not commit generated files such as `nvim.log`, `_site/`, or
`.jekyll-cache/`.

## Build, Test, and Development Commands

The plugin has no build step. Run these commands from the repository root:

- `for spec in tests/*_spec.lua; do nvim --headless -u NONE -i NONE -l "$spec"; done` runs
  the full headless suite. `tests/tools_spec.lua` is the quickest focused operation check;
  `tests/layout_spec.lua`, `tests/relayout_spec.lua`, and `tests/capabilities_spec.lua`
  cover the adaptive-window and capability contracts.
- `stylua --check .` checks Lua formatting; run `stylua .` to apply formatting.
- `selene .` lints Lua using the repository's Lua 5.1 and Neovim global definitions.
- `pre-commit install` enables local formatting and repository-hygiene hooks.

For manual testing, add this checkout to Neovim's runtime path. Call
`require("buoy").setup()` only when testing explicit overrides; otherwise let automatic
setup run, then use `:Buoy`, `:BuoyToggle`, `<F2>`, or `<S-F2>`.

## Coding Style & Naming Conventions

Follow `.stylua.toml`: two-space indentation, Unix line endings, double quotes where
practical, and a 100-column limit. Use `snake_case` for local functions and module fields,
uppercase names for constants, and `M` for exported module tables. Prefer Neovim APIs over
shell commands. Document public behavior with concise LuaDoc and preserve Neovim 0.11
compatibility unless a change explicitly raises the minimum version.

## Testing Guidelines

Tests are self-contained Lua scripts rather than an external framework. Add focused
assertions to `tests/*_spec.lua`, with failure labels that state the expected behavior.
Cover successful interactions plus null and invalid-input paths. There is no numeric
coverage target, but every behavior change should include a regression test. CI runs the
full suite on Ubuntu with Neovim 0.11.0, stable, and nightly; nightly is allowed to fail.

Keep PTY coverage deterministic with `nvim_open_term()` rather than timing real terminal
output. `tests/agent_cli_spec.lua` and `tests/hook_spec.lua` open real local RPC servers, so
restricted sandboxes may need permission to create their sockets; an `operation not
permitted` failure there is an environment limitation, not automatically a plugin
regression.

## Interaction Semantics

Preserve the interaction split. The two keymaps are layout-aware: the primary key
(`<F2>`, `keymaps.primary`) performs the layout's always-on action — focus-switch in a
`vsplit`, show/hide in a `float` — and the secondary key (`<S-F2>`, `keymaps.secondary`)
does the other. When the agent is closed, the layout it would open into decides, so either
key opens it. Neither hiding nor focus-switching kills the terminal session. `:Buoy` opens
or focuses the agent (it does not switch back to code) and `:BuoyToggle` shows or hides it,
regardless of layout. Keep ranged command invocation working so Visual-mode `:Buoy` and
`:BuoyToggle` preserve the same selection handoff as the keymaps.

A debounced `VimResized` handler keeps an open agent in step with the editor size. Under
`style = "auto"`, crossing the width boundary rebuilds into the other layout by closing and
reopening the window around the same terminal buffer; a same-layout resize refreshes
geometry in place (repositions a float, re-asserts a vsplit's width). This relies on the
session living in the buffer, not the window — preserve that invariant when changing the
open, hide, or rebuild paths, and keep the rebuild focus-preserving and confined to the
agent's tabpage. A rebuild also reselects an active Visual selection with `gv`; window
changes end Visual mode, so any new teardown path has to restore it. Because relayout only
acts on the agent's own tabpage, a resize that happens while another tab is active is a
no-op there; a `TabEnter` handler performs the missed relayout when the agent's tab regains
focus. Keep both entry points in step.

`style = "auto"` resolves against the real window layout, not `vim.o.columns` alone: it takes
the layout's shape from the current windows and its size from `columns`, so a tab already
divided into columns floats instead of squeezing every code window below `window.width`.
Fixed-width sidebars count as occupied screen columns, not as a sum of window widths, so
vertically stacked sidebars that share columns contribute once. Keep that resolver
ratio-based — an absolute-width reading is untestable headlessly, where setting
`vim.o.columns` updates the option a tick before the windows follow. `window.width` is a
fixed integer count of text columns with a minimum of 40, clamped only when rendering into a
narrow editor. The split sets `winfixwidth` to hold that count, and the user's own window
commands deliberately do not trigger a relayout.

By default, closing the last code window also quits an agent split;
`window.stay = true` lets the agent outlive it. Hiding still always hides: when the agent is
the last ordinary window, `hide()` first restores the alternate buffer or a reusable
fallback buffer before closing, rather than surfacing `E444`. Preserve the cached fallback;
repeated hide cycles must not accumulate listed empty buffers.

The three `context` switches default to `true` and are defined only in
`capabilities.lua`. `expose_buffers` and `expose_diagnostics` control both the instructions
shown to the agent and dispatch authorization for their read operations.
`expose_editor_context` controls the per-prompt hook, snapshot, and selection handoff.
`set_cursor_position` stays available even when every read surface is disabled; keep its
1-based coordinate contract in the generated instructions. Add or change capabilities
through the registry rather than duplicating capability lists across config, instructions,
and tools.

Configuration is applied once per Neovim session. Explicit `setup()` during startup wins
over scheduled zero-config setup, later calls warn, and `BUOY_AGENT` is the supported
per-session agent override. Validate configuration before setting the one-shot setup flag so
a rejected value does not block a corrected call. Visual capture uses Neovim's region APIs
for exact charwise, linewise, and blockwise text; do not restore a whole-line fallback.
Preserve the visual-selection handoff and cleanup lifecycle when changing focus, hiding,
rebuilding, or terminal exit behavior.

## Commit & Pull Request Guidelines

Use Conventional Commit subjects such as `feat: add ...`, `fix: handle ...`, and
`docs: clarify ...`. Use `feat!:` or a `BREAKING CHANGE:` footer for incompatible changes.
Target `main` with a concise problem/solution description, linked issues when relevant,
and verification commands. Include screenshots or recordings for window or interaction
changes. Keep pull requests scoped and ensure tests, StyLua, and Selene pass.
