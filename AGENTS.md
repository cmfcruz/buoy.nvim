# Repository Guidelines

## Documentation Ownership

Keep the README user-oriented: installation, configuration, commands, behavior, supported
agents, and user-facing limitations belong there. Put all development and contribution
material in this `AGENTS.md`, including architecture and directory notes, implementation
invariants, local commands, testing details, coding style, pull-request expectations, and
release mechanics. The README should link here instead of duplicating those instructions so
human contributors and coding agents work from the same guide. When a change affects both
users and contributors, update the user-facing behavior in the README and the implementation
contract here.

## Project Structure & Module Organization

`buoy.nvim` is a Lua plugin for Neovim 0.11+. Runtime modules live in `lua/buoy/`: `init.lua`
owns one-shot setup, socket publication, keymaps, and resize/tab handlers; `startup.lua`
owns deferred automatic opening and the one-shot key reminder; `terminal.lua` owns the agent
window, layout, and terminal job. `context.lua` caches editor state and visual handoffs;
`tools.lua` and `navigate.lua` implement live reads and cursor navigation; `capabilities.lua`
is the single source of truth for the `context` switches; and `error.lua` builds the shared
error result. `agents.lua` is the ordered agent catalog, `launcher.lua` dispatches through a
uniform adapter contract, and `instructions.lua` builds shared guidance, paths, and bridge
commands. User commands and the scheduled zero-configuration setup entry point live in
`plugin/buoy.lua`.

All agent-specific runtime integration code lives in `lua/buoy/custom/`. `claude.lua`,
`codex.lua`, `pi.lua`, and `copilot.lua` map the shared integration onto each CLI. Adjacent
helpers stay with their agent: `codex_protocol.lua` implements the app-server JSON-RPC handshake,
`copilot_hook.lua` transforms Copilot prompt-hook input, and `pi_hooks.ts` uses Pi's extension
API. Every adapter exports `resolve(opts, callback)`, receives the shared `cmd`, `cwd`, and
`context` fields, and calls back with its launch argv and optional environment. Keep agent
policy out of `launcher.lua`; add an adapter here and register its name, default command,
title, and module in `agents.lua`.

The adapters deliberately preserve each CLI's own instruction and hook model:

- Claude adds shared guidance with `--append-system-prompt` and passes hooks through inline
  `--settings` JSON.
- Codex asks `codex app-server` for the effective `developer_instructions`, appends shared
  guidance, and renders session-scoped TOML overrides. Resolution is asynchronous and has a
  two-second timeout; failure launches without an instruction override while retaining the
  enabled automatic hooks.
- Pi passes guidance and hook commands through its terminal environment and loads
  `pi_hooks.ts` with `--extension`; the extension appends to Pi's assembled system prompt.
- Copilot asynchronously verifies CLI 1.0.83 or newer, then creates a session-local plugin
  directory containing `buoy.instructions.md`. Preserve existing
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, reuse plugin directories for equal guidance, and remove
  them on `VimLeavePre`. A failed version check or plugin setup launches the plain terminal
  without integration.

Adapters may invoke their callback synchronously or asynchronously. `terminal.lua` keeps a
new scratch buffer unmodifiable while resolution is pending, schedules terminal creation,
and merges the optional adapter environment with `NVIM_CONTEXT_SOCKET`. Preserve that
boundary when adding an agent or changing startup.

`bridge/buoy.lua` is the single agent-invoked entry point for per-prompt context, post-tool
buffer refresh, and private one-shot operations. Its generic custom-hook mode dispatches to
agent handlers such as `lua/buoy/custom/copilot_hook.lua`; the shared context/checktime modes
remain stdin-independent. `bridge/nvim_rpc.lua` is its private shared Neovim RPC transport.
There is no MCP server; the CLI exposes exactly `get_buffer_range`, `get_diagnostics`, and
`set_cursor_position`, while reserved hook modes serve lifecycle events. Bridge children run
with `nvim --headless -u NONE -i NONE -l`. The non-Windows path generates POSIX hook commands
and is supported on Linux and macOS. The implementation explicitly bypasses all adapters on
`win32`, starts the configured command directly, and keeps the terminal UI without live
editor context.

Self-contained headless specs live in `tests/`. Project-site media live under `docs/`, while
`_config.yml` configures the root-based GitHub Pages site that renders the README as its
index. `.stylua.toml`, `selene.toml`, `vim.yml`, and `.pre-commit-config.yaml` define local
code checks. CI and release workflows live in `.github/workflows/`;
`release-please-config.json`, `.release-please-manifest.json`, `version.txt`, and
`CHANGELOG.md` hold release state. Do not commit generated files such as `nvim.log`, `_site/`,
or `.jekyll-cache/`.

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

StyLua formats Lua only. Preserve the existing TypeScript style in `lua/buoy/custom/pi_hooks.ts`
(tabs, semicolons, and explicit types). Keep hook scripts quiet on recoverable failures
because their stdout is part of an agent protocol.

## Testing Guidelines

Tests are self-contained Lua scripts rather than an external framework. Add focused
assertions to `tests/*_spec.lua`, with failure labels that state the expected behavior.
Cover successful interactions plus null and invalid-input paths where they affect a Buoy
contract. Each regression test should identify a plausible Buoy defect it would catch;
do not add tests solely for coverage counts or for reversible, low-impact edits. CI runs the
full suite on Ubuntu with Neovim 0.11.0, stable, and nightly; nightly is allowed to fail.

Protect the integration contracts Buoy owns, not an agent's end-to-end behavior. Adapter
specs should assert the argv, environment, instruction text, hook configuration, protocol
messages, and fallback decisions Buoy passes across the boundary. Do not launch installed
agent CLIs, fake their model backends, or assert how an agent discovers instructions, invokes
tools, resumes sessions, or otherwise behaves after accepting that configuration. Those are
upstream implementation details and make the suite fragile. It is appropriate to run real
headless Neovim children for bridge and hook specs because both sides of that RPC contract
belong to this repository.

Assert observable outcomes: returned contents, actual cursor movement, preserved sessions,
or the exact configuration passed across a boundary. A success-path check that merely
excludes one error code can pass on unrelated failures; require the intended success and
its effect. Avoid standalone type/existence checks when the next assertion already uses
the value, load-only smoke tests, and tests of standard-library or Neovim behavior alone.
Keep fixture preconditions when they prevent a regression scenario from silently testing
the wrong state. Test shared rules in their owning spec; adapter specs should verify their
mapping of those rules. Prefer before/after resource checks over fixed allocation counts,
and avoid binding assertions to prose line wrapping or incidental implementation details.

Keep PTY coverage deterministic with `nvim_open_term()` rather than timing real terminal
output. `tests/bridge_cli_spec.lua`, `tests/hook_spec.lua`, and `tests/copilot_spec.lua` open
real local RPC servers, so restricted sandboxes may need permission to create their sockets;
an `operation not permitted` failure there is an environment limitation, not automatically
a plugin regression. Keep shared dispatch behavior in `launcher_spec.lua` and agent-specific
argv, environment, protocol, and fallback behavior in the corresponding `claude_spec.lua`,
`codex_spec.lua`, `pi_spec.lua`, or `copilot_spec.lua`.

## Interaction Semantics

Preserve the interaction split. The two keymaps are layout-aware: the primary key
(`<F2>`, `keymaps.primary`) performs the layout's always-on action — focus-switch in a
`vsplit`, show/hide in a `float` — and the secondary key (`<S-F2>`, `keymaps.secondary`)
does the other. When the agent is closed, the layout it would open into decides, so either
key opens it. Neither hiding nor focus-switching kills the terminal session. `:Buoy` opens
or focuses the agent (it does not switch back to code) and `:BuoyToggle` shows or hides it,
regardless of layout. Keep ranged command invocation working so Visual-mode `:Buoy` and
`:BuoyToggle` preserve the same selection handoff as the keymaps.

Automatic startup runs only when Neovim has an attached UI, opens at most once, and restores
the original tab/window focus. Show the reminder only after an agent window actually opens;
the first configured Buoy key action dismisses it without swallowing that action.

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
`expose_editor_context` controls both bridge hooks, the per-prompt snapshot, and the
selection handoff. `set_cursor_position` stays available even when every read surface is
disabled; keep its 1-based coordinate contract in the generated instructions. Add or change
capabilities through the registry rather than duplicating capability lists across config,
instructions, and tools.

Read operations accept only loaded buffers so they can return unsaved editor state. Explicit
files must be absolute. Keep buffer pages capped at 500 lines, diagnostic pages capped at 200
records, and encoded results within 24,576 bytes, with continuation fields when truncation is
possible. Navigation must target an ordinary editing window rather than the agent terminal or
a float, seed the destination window's jumplist before moving, and preserve the one-`Ctrl-O`
return path for same-buffer and cross-buffer jumps.

Agent adapters map their native file-mutation lifecycle events onto the shared post-tool hook
and intentionally exclude shell writes. Its RPC command must check every loaded buffer
explicitly: a bare non-interactive `:checktime` misses hidden buffers, which the private CLI
can still read. Preserve Neovim's normal safety semantics — clean buffers reload only under
`autoread`, modified buffers are never forced — and keep the hook stdin-independent,
output-free, and successful even when the bridge cannot be reached.

During setup, `init.lua` deliberately forces Neovim to allocate its hidden autocmd window
while a non-terminal buffer is active. Without that inoculation, a first hidden-buffer option
read while the agent float is focused can briefly resize the PTY to the editor width. Keep
the scratch-buffer allocation, terminal guard, and `BufEnter` retry together unless Neovim's
underlying behavior is proven fixed across supported versions.

Configuration is applied once per Neovim session. Explicit `setup()` during startup wins
over scheduled zero-config setup, later explicit calls warn, and `BUOY_AGENT` is the supported
per-session agent override. Automatic detection follows the order in `agents.lua`: Claude,
Codex, Pi, then Copilot. Validate configuration before setting the one-shot setup flag so a
rejected value does not block a corrected call. Visual capture uses Neovim's region APIs for
exact charwise, linewise, and blockwise text; do not restore a whole-line fallback. Preserve
the visual-selection handoff and cleanup lifecycle when changing focus, hiding, rebuilding,
or terminal exit behavior.

## Commit & Pull Request Guidelines

Use Conventional Commit subjects such as `feat: add ...`, `fix: handle ...`, and
`docs: clarify ...`. Use `feat!:` or a `BREAKING CHANGE:` footer for incompatible changes.
Target `main` with a concise problem/solution description, linked issues when relevant,
and verification commands. Include screenshots or recordings for window or interaction
changes. Keep pull requests scoped and ensure tests, StyLua, and Selene pass.

Versioning is automated with Release Please. Merging `feat:` or `fix:` commits to `main`
opens a release PR that bumps `version.txt` and updates the changelog; merging that release
PR creates the tag and release.
