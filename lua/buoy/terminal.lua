--- Floating terminal hosting the agent's official TUI (passthrough PTY).
--- The terminal buffer and job survive toggling; hiding the window
--- never kills the agent session.

local M = {}

local state = { buf = nil, win = nil, job = nil }

local function win_valid()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function open_window()
  local plugin = require("buoy")
  local cfg = plugin.config.window

  if cfg.style == "vsplit" then
    vim.cmd("botright vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.win, math.floor(vim.o.columns * cfg.width))
    vim.api.nvim_win_set_buf(state.win, state.buf)
  else
    local width = math.floor(vim.o.columns * cfg.width)
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
end

local function start_job()
  local plugin = require("buoy")
  state.job = vim.fn.termopen(plugin.config.cmd, {
    env = {
      -- Belt and suspenders: $NVIM is set automatically for jobs spawned
      -- from Neovim, but we also export an explicit variable in case the
      -- agent forwards env to MCP servers. NVIM_CONTEXT_SOCKET is the
      -- agent-neutral name; CODEX_NVIM_SOCKET is kept as a back-compat alias.
      NVIM_CONTEXT_SOCKET = plugin.socket,
      CODEX_NVIM_SOCKET = plugin.socket,
    },
    on_exit = function()
      state.job = nil
      if win_valid() then
        vim.api.nvim_win_close(state.win, true)
      end
      if buf_valid() then
        vim.api.nvim_buf_delete(state.buf, { force = true })
      end
      state.buf, state.win = nil, nil
    end,
  })
end

function M.open()
  -- Paint the cached selection so it stays visible while focus is in the popup.
  -- Done here (on open) rather than on visual-mode exit, so a plain Esc leaves no
  -- highlight behind -- only triggering the agent retains it.
  require("buoy.context").paint_selection()

  if win_valid() then
    vim.api.nvim_set_current_win(state.win)
    vim.cmd.startinsert()
    return
  end

  local fresh = not buf_valid()
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
    state.win = nil
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
