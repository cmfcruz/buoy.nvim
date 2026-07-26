# Repository Guidelines

## Project Structure & Module Organization

`buoy.nvim` is a Lua plugin for Neovim 0.11+. Runtime modules live in `lua/buoy/`: `init.lua`
owns one-shot setup, socket publication, and default keymaps; `terminal.lua` owns the agent
window and terminal job; `context.lua` caches editor state and visual handoffs; `tools.lua`
and `navigate.lua` implement live reads and cursor navigation. `launcher.lua`,
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
live in `tests/`. CI and release automation live in `.github/workflows/`. Do not commit
generated files such as `nvim.log`.

## Build, Test, and Development Commands

The plugin has no build step. Run these commands from the repository root:

- `for spec in tests/*_spec.lua; do nvim --headless -u NONE -i NONE -l "$spec"; done` runs
  the full headless suite. `tests/tools_spec.lua` is the quickest focused operation check.
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

Preserve the interaction split: `<F2>` opens the agent or switches focus between it and the
last editing window while keeping the agent visible. `<S-F2>` and `:BuoyToggle` show or
hide the window without killing the terminal session. `:Buoy` opens or focuses the agent;
it does not switch back to code. Keep ranged command invocation working so Visual-mode
`:Buoy` and `:BuoyToggle` preserve the same selection handoff as their keymaps.

Configuration is applied once per Neovim session. Explicit `setup()` during startup wins
over scheduled zero-config setup, later calls warn, and `BUOY_AGENT` is the supported
per-session agent override. Preserve the visual-selection handoff and cleanup lifecycle
when changing focus, hiding, or terminal exit behavior.

## Commit & Pull Request Guidelines

Use Conventional Commit subjects such as `feat: add ...`, `fix: handle ...`, and
`docs: clarify ...`. Use `feat!:` or a `BREAKING CHANGE:` footer for incompatible changes.
Target `main` with a concise problem/solution description, linked issues when relevant,
and verification commands. Include screenshots or recordings for window or interaction
changes. Keep pull requests scoped and ensure tests, StyLua, and Selene pass.
