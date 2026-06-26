--- Tracks editor context (file, cursor, last visual selection) from
--- *real* buffers. This cache is what the MCP tools serve, because when
--- the user is typing in the agent popup, the "current" window is the
--- terminal — the interesting context is wherever they were editing.

local M = {}

M.state = {
  file = nil,        -- absolute path of last real file buffer
  filetype = nil,
  cursor = nil,      -- { line = 1-based, col = 1-based }
  selection = nil,   -- { file, start_line, end_line, mode, text }
}

local function is_real_buffer(buf)
  return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function update_position()
  local buf = vim.api.nvim_get_current_buf()
  if not is_real_buffer(buf) then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  M.state.file = vim.api.nvim_buf_get_name(buf)
  M.state.filetype = vim.bo[buf].filetype
  M.state.cursor = { line = pos[1], col = pos[2] + 1 }
end

--- Capture the selection when leaving visual mode ('< and '> marks are
--- set at that point). Uses getregion() when available (nvim 0.10+) for
--- correct charwise/blockwise extraction; falls back to whole lines.
local function capture_selection()
  local buf = vim.api.nvim_get_current_buf()
  if not is_real_buffer(buf) then
    return
  end

  local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  if s[2] == 0 or e[2] == 0 then
    return
  end

  local vmode = vim.fn.visualmode()
  local text
  if vim.fn.has("nvim-0.10") == 1 then
    text = table.concat(vim.fn.getregion(s, e, { type = vmode }), "\n")
  else
    text = table.concat(
      vim.api.nvim_buf_get_lines(buf, s[2] - 1, e[2], false),
      "\n"
    )
  end

  M.state.selection = {
    file = vim.api.nvim_buf_get_name(buf),
    start_line = s[2],
    end_line = e[2],
    mode = vmode,
    text = text,
  }
end

function M.setup()
  local group = vim.api.nvim_create_augroup("BuoyContext", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    callback = update_position,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "[vV\x16]*:*", -- leaving visual / V-line / V-block
    callback = capture_selection,
  })
end

return M
