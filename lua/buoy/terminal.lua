--- Terminal hosting the agent's official TUI (passthrough PTY).
--- The terminal buffer and process survive toggling; hiding the window
--- never kills the agent session.

local M = {}

local state = { buf = nil, win = nil }

local function win_valid()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function clear_context()
  require("buoy.context").clear_selection()
end

local function install_close_cleanup(win)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      clear_context()
      if state.win == win then
        state.win = nil
      end
    end,
  })
end

local function open_window()
  local plugin = require("buoy")
  local cfg = plugin.config.window
  local width = math.floor(vim.o.columns * cfg.width)

  if cfg.style == "vsplit" then
    vim.cmd("botright vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.win, width)
    vim.api.nvim_win_set_buf(state.win, state.buf)
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
  install_close_cleanup(state.win)
end

local function start_term(argv)
  local plugin = require("buoy")
  local env
  if vim.fn.has("win32") == 0 then
    env = { NVIM_CONTEXT_SOCKET = plugin.socket }
  end
  vim.api.nvim_buf_call(state.buf, function()
    vim.fn.termopen(argv, {
      env = env,
      on_exit = function()
        if win_valid() then
          vim.api.nvim_win_close(state.win, true)
        end
        if buf_valid() then
          vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        state.buf = nil
      end,
    })
  end)
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

  if win_valid() then
    vim.api.nvim_set_current_win(state.win)
    vim.cmd.startinsert()
    return
  end

  if fresh then
    state.buf = vim.api.nvim_create_buf(false, false)
  end

  open_window()

  if fresh then
    -- termopen must run with the target buffer current.
    start_job()
  end

  vim.cmd.startinsert()
end

function M.hide()
  if win_valid() then
    vim.api.nvim_win_close(state.win, true)
  end
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

return M
