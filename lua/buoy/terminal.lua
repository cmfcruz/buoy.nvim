--- Terminal hosting the agent's official TUI (passthrough PTY).
--- The terminal buffer and process survive toggling; hiding the window
--- never kills the agent session.

local M = {}

local state = { buf = nil, win = nil, rebuilding = false, replacement_buf = nil }

local function win_valid()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function clear_context()
  require("buoy.context").clear_selection()
end

--- True when the agent lives in a split (not a float) and is the only ordinary
--- window left in its tabpage, so closing it would leave the tab empty.
local function agent_is_last_ordinary_window()
  if not win_valid() then
    return false
  end
  -- A float overlays ordinary windows, so it never strands one: skip it.
  if vim.api.nvim_win_get_config(state.win).relative ~= "" then
    return false
  end
  local tab = vim.api.nvim_win_get_tabpage(state.win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= state.win and vim.api.nvim_win_get_config(win).relative == "" then
      return false
    end
  end
  return true
end

local last_window_guard_installed = false

--- Quit the agent split once it becomes the last ordinary window in its
--- tabpage (which, on the last tab, exits Neovim). Installed once per session
--- and gated on `window.stay`, read live so the flag applies without a restart.
local function ensure_last_window_guard()
  if last_window_guard_installed then
    return
  end
  last_window_guard_installed = true

  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("BuoyLastWindow", { clear = true }),
    callback = function(args)
      if require("buoy").config.window.stay then
        return
      end
      -- Only react to *other* windows closing; the agent's own close is
      -- handled by install_close_cleanup.
      if not win_valid() or tonumber(args.match) == state.win then
        return
      end
      -- Defer: during WinClosed the layout still counts the closing window.
      vim.schedule(function()
        if agent_is_last_ordinary_window() then
          vim.api.nvim_win_call(state.win, function()
            vim.cmd("quit")
          end)
        end
      end)
    end,
  })
end

local function install_close_cleanup(win)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- A rebuild's close is a mid-handoff teardown, not the end of one: skip
      -- the clear so the selection survives into the reopened window.
      if not state.rebuilding then
        clear_context()
      end
      if state.win == win then
        state.win = nil
      end
    end,
  })
end

--- The agent's fixed text-column width, clamped so the window (plus a floating
--- border) still fits inside a narrow editor.
local function compute_width(cfg)
  return math.max(1, math.min(cfg.width, vim.o.columns - 2))
end

--- Shape of the current tabpage's ordinary (non-floating) windows. Floats are
--- excluded: they overlay the layout rather than divide it.
---
--- Windows carrying 'winfixwidth' — file trees, symbol outlines, and the
--- agent's own split — keep their columns when the layout changes, so they are
--- measured as fixed overhead instead of as code that a split would squeeze.
--- Returns the narrowest resizable code window (nil when there is none), the
--- total width the layout spans, and the fixed overhead with and without the
--- agent's own split, each including the window's separator column.
local function layout_metrics()
  local agent_split = win_valid()
      and vim.api.nvim_win_get_config(state.win).relative == ""
      and state.win
    or nil
  local narrowest, layout_width, fixed_agent = nil, 0, 0
  local fixed_columns = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local width = vim.api.nvim_win_get_width(win)
      local col = vim.fn.win_screenpos(win)[2]
      -- win_screenpos is 1-based, so the right edge is col - 1 + width; the
      -- widest edge is how many columns the whole layout occupies.
      layout_width = math.max(layout_width, col - 1 + width)
      if win == agent_split then
        fixed_agent = width + 1
      elseif vim.wo[win].winfixwidth then
        for fixed_col = col, col + width do
          fixed_columns[fixed_col] = true
        end
      elseif not narrowest or width < narrowest then
        narrowest = width
      end
    end
  end
  return narrowest, layout_width, vim.tbl_count(fixed_columns), fixed_agent
end

--- Resolve `window.style` to a concrete layout. An explicit "vsplit" or
--- "float" always wins. "auto" keeps a vsplit while every code window would
--- stay wider than the agent's fixed width, and floats once the split would
--- squeeze one of them below it — so a narrow editor, or a tab already divided
--- into columns, gets an overlay instead of crowded code.
local function resolve_style(style, width)
  if style == "vsplit" or style == "float" then
    return style
  end

  local narrowest, layout_width, fixed_other, fixed_agent = layout_metrics()
  if not narrowest then
    -- Nothing here would be squeezed: the tab holds only fixed-width windows
    -- (and possibly the agent split itself), so a split costs them nothing.
    return "vsplit"
  end

  -- Compare like with like. The narrowest code window holds some share of
  -- today's resizable area; project that share onto the resizable area the
  -- editor would have with the agent split in it. Taking the layout's shape
  -- from the real windows and its size from 'columns' is what keeps the
  -- decision correct in a tab already divided into columns, where treating the
  -- editor as a single code window would squeeze every window below the
  -- agent's own width.
  local code_area_now = math.max(layout_width - fixed_other - fixed_agent, 1)
  local code_area_next = math.max(vim.o.columns - fixed_other - width - 1, 1)
  local projected = math.floor(narrowest / code_area_now * code_area_next)
  return projected > width and "vsplit" or "float"
end

--- The layout the agent currently occupies, or — when it is hidden — the one it
--- would open into under the current config and editor width. Drives the
--- layout-aware keymaps so a key's action tracks what is (or would be) on screen.
local function current_layout()
  if win_valid() then
    return vim.api.nvim_win_get_config(state.win).relative ~= "" and "float" or "vsplit"
  end
  local cfg = require("buoy").config.window
  return resolve_style(cfg.style, compute_width(cfg))
end

local function open_window()
  local plugin = require("buoy")
  local cfg = plugin.config.window
  local width = compute_width(cfg)
  local style = resolve_style(cfg.style, width)

  if style == "vsplit" then
    vim.cmd("botright vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.win, width)
    vim.api.nvim_win_set_buf(state.win, state.buf)
    -- `width` is a fixed column count, so hold it against the window commands
    -- that would otherwise redistribute it: `<C-w>=` and every new split
    -- equalize around a window unless it is pinned.
    vim.wo[state.win].winfixwidth = true
  else
    local height = vim.o.lines - 4
    state.win = vim.api.nvim_open_win(state.buf, true, {
      relative = "editor",
      row = 1,
      col = vim.o.columns - width - 1,
      width = width,
      height = height,
      border = cfg.border,
      style = "minimal",
      title = plugin.config.title,
      title_pos = "center",
    })
  end

  vim.wo[state.win].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"
  -- Strip gutters so the terminal's text area equals the window width, giving
  -- the agent the full cfg.width columns. The float already does this via
  -- style = "minimal"; a vsplit inherits global 'number'/'signcolumn'/etc.
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldcolumn = "0"
  install_close_cleanup(state.win)
  ensure_last_window_guard()
end

local function start_term(argv)
  local plugin = require("buoy")
  local env
  if vim.fn.has("win32") == 0 then
    env = { NVIM_CONTEXT_SOCKET = plugin.socket }
  end
  vim.api.nvim_buf_call(state.buf, function()
    -- launcher.resolve may run async; the buffer was locked while we waited so
    -- stray keystrokes could not modify it and break termopen. Unlock now.
    vim.bo[state.buf].modifiable = true
    vim.fn.termopen(argv, {
      env = env,
      on_exit = function()
        if win_valid() then
          M.hide()
        end
        if buf_valid() then
          vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        state.buf = nil
      end,
    })
  end)
  -- Only now is the buffer a terminal; entering insert earlier could have
  -- modified the scratch buffer and failed termopen. Guard against the user
  -- having moved focus during the async wait.
  if vim.api.nvim_get_current_win() == state.win then
    vim.cmd.startinsert()
  end
end

local function start_job()
  local plugin = require("buoy")
  require("buoy.launcher").resolve(
    plugin.config.agent,
    plugin.config.cmd,
    vim.fn.getcwd(),
    start_term
  )
end

function M.open()
  local fresh = not buf_valid()
  if fresh then
    -- Guard before creating any UI: termopen() throws E475 on a missing
    -- executable, which would otherwise abort mid-open and leave a dead float.
    local cmd = require("buoy").config.cmd
    if vim.fn.executable(cmd) ~= 1 then
      vim.notify(
        (
          "buoy: no compatible agent is installed ('%s' not found on $PATH). "
          .. "Install Claude Code or Codex, or point `cmd` in setup() at your agent CLI."
        ):format(cmd),
        vim.log.levels.ERROR
      )
      return
    end
  end

  -- Paint a visual-mode handoff so it stays visible while focus is in the agent.
  -- Esc/yank exits clear the selection instead of caching stale context.
  require("buoy.context").paint_selection()

  -- Leave visual mode before moving focus: nvim_set_current_win keeps visual
  -- mode active, so the selection would re-anchor inside the terminal buffer
  -- and startinsert (a no-op outside normal mode) would never reach terminal
  -- insert. paint_selection has already captured the handoff, and its
  -- preserve_next_visual_exit flag keeps it across this mode change.
  -- (A bare Esc is discarded when executed :normal!-style; CTRL-\ CTRL-N is
  -- the documented mode-reset that works there.)
  if vim.fn.mode():match("[vV\22]") then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true),
      "nx",
      false
    )
  end

  if win_valid() then
    vim.api.nvim_set_current_win(state.win)
    vim.cmd.startinsert()
    return
  end

  if fresh then
    state.buf = vim.api.nvim_create_buf(false, false)
    -- launcher.resolve may resolve asynchronously (Codex spawns app-server and
    -- round-trips its config before start_term runs). Lock the scratch buffer so
    -- keystrokes during that window cannot mark it modified and break termopen.
    vim.bo[state.buf].modifiable = false
  end

  open_window()

  if fresh then
    -- termopen must run with the target buffer current. start_term enters insert
    -- mode itself once the terminal exists, so do not startinsert here.
    start_job()
    return
  end

  vim.cmd.startinsert()
end

--- Put an ordinary window back beside the agent so closing the agent does not
--- strand the tabpage. Reuses the alternate buffer — with `window.stay` the
--- agent typically outlived the user's last code window, so that buffer is the
--- file they were editing — and falls back to an empty one.
local function open_replacement_window()
  local alt = vim.fn.bufnr("#")
  local buf
  if alt > 0 and alt ~= state.buf and vim.api.nvim_buf_is_valid(alt) then
    buf = alt
  elseif
    state.replacement_buf
    and state.replacement_buf ~= state.buf
    and vim.api.nvim_buf_is_valid(state.replacement_buf)
  then
    buf = state.replacement_buf
  else
    buf = vim.api.nvim_create_buf(true, false)
    state.replacement_buf = buf
  end
  vim.api.nvim_open_win(buf, false, { split = "left", win = state.win })
end

function M.hide()
  if not win_valid() then
    return
  end
  -- Neovim refuses to close the last window (E444), which `window.stay = true`
  -- makes reachable: the agent can outlive every other window in its tabpage.
  -- Hiding still means hiding, so restore an ordinary window and then close.
  if agent_is_last_ordinary_window() then
    open_replacement_window()
  end
  vim.api.nvim_win_close(state.win, true)
end

--- Switch focus between the agent terminal and the last active window without
--- hiding its window. Opens the terminal if it isn't visible yet.
function M.focus_toggle()
  if not win_valid() or vim.api.nvim_get_current_win() ~= state.win then
    M.open()
    return
  end

  vim.cmd.stopinsert()
  -- Leaving the agent is the end of the handoff, same as hiding the window:
  -- drop the painted selection so it can't go stale while editing resumes.
  clear_context()
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev == 0 or prev == state.win or not vim.api.nvim_win_is_valid(prev) then
    prev = nil
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= state.win and vim.api.nvim_win_get_config(win).relative == "" then
        prev = win
        break
      end
    end
  end
  if prev then
    vim.api.nvim_set_current_win(prev)
  end
end

function M.toggle()
  if win_valid() then
    M.hide()
  else
    M.open()
  end
end

--- Layout-aware key actions. The primary key (F2 by default) does the layout's
--- "always-on" action: focus in a vsplit, where the agent is always visible, or
--- show/hide in a float, where it overlaps the code. The secondary key (S-F2)
--- does the other. See current_layout() for how the layout is determined.
function M.on_primary()
  if current_layout() == "float" then
    M.toggle()
  else
    M.focus_toggle()
  end
end

function M.on_secondary()
  if current_layout() == "float" then
    M.focus_toggle()
  else
    M.toggle()
  end
end

--- Rebuild the agent window in the resolved layout without disturbing its
--- session: the terminal buffer outlives the window, so close the current
--- window and reopen through open_window(), then restore whichever side (agent
--- or code) held focus. Also preserves an active visual-selection handoff:
--- state.rebuilding suppresses install_close_cleanup's clear_context() across
--- the close, since this teardown is not the end of the handoff, just a
--- window swap mid-session. Assumes state.win is valid and on the current
--- tabpage.
local function rebuild_window()
  local had_focus = vim.api.nvim_get_current_win() == state.win
  local prev = (not had_focus) and vim.api.nvim_get_current_win() or nil
  -- Entering and leaving windows ends Visual mode, so a rebuild triggered while
  -- the user is mid-selection would silently discard it. Note it now and
  -- reselect below.
  local had_selection = prev ~= nil and vim.fn.mode():match("[vV\22]") ~= nil

  state.rebuilding = true
  M.hide() -- closes the window; state.buf (the running agent) is untouched
  local ok, err = pcall(open_window) -- reopens the resolved layout for the same buffer, focusing the agent
  state.rebuilding = false
  if not ok then
    error(err, 0)
  end

  if had_focus then
    vim.cmd.startinsert()
  elseif prev and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
    if had_selection then
      -- `gv` reselects the region the rebuild just ended, restoring its mode
      -- (charwise, linewise, or blockwise), anchor, and cursor together.
      vim.cmd("normal! gv")
    end
  end
end

--- Re-evaluate the agent's layout against the current editor size and adapt in
--- place. With `style = "auto"` a resize that crosses the vsplit/float boundary
--- rebuilds into the other layout (reusing the session); otherwise the existing
--- window's geometry is refreshed so a float stays anchored and a vsplit keeps
--- its fixed width. A no-op when the agent is hidden or on another tabpage.
function M.relayout()
  if not win_valid() or not buf_valid() then
    return
  end
  -- A rebuild uses botright vsplit, which targets the current tabpage, and the
  -- geometry math is global; only act while the agent is on the active tab. A
  -- backgrounded agent re-detects its layout on its next show.
  if vim.api.nvim_win_get_tabpage(state.win) ~= vim.api.nvim_get_current_tabpage() then
    return
  end

  local cfg = require("buoy").config.window
  local width = compute_width(cfg)
  local target = resolve_style(cfg.style, width)

  if target ~= current_layout() then
    if target == "float" and agent_is_last_ordinary_window() then
      return -- no ordinary window left to overlay; keep the split
    end
    rebuild_window()
    return
  end

  -- Same layout: keep its geometry in step with the resized editor.
  if target == "float" then
    vim.api.nvim_win_set_config(state.win, {
      relative = "editor",
      row = 1,
      col = vim.o.columns - width - 1,
      width = width,
      height = vim.o.lines - 4,
    })
  else
    vim.api.nvim_win_set_width(state.win, width)
  end
end

local resize_timer

--- Debounced VimResized entry point: a resize drag emits a burst of events, so
--- coalesce them and re-lay-out once the size settles.
function M.on_resize()
  if resize_timer and not resize_timer:is_closing() then
    resize_timer:stop()
    resize_timer:close()
  end
  resize_timer = vim.defer_fn(M.relayout, 60)
end

return M
