--- Tracks editor context (file, cursor, last visual selection) from
--- *real* buffers. This cache is what the MCP tools serve, because when
--- the user is typing in the agent popup, the "current" window is the
--- terminal — the interesting context is wherever they were editing.

local M = {}

M.state = {
  file = nil, -- absolute path of last real file buffer
  filetype = nil,
  cursor = nil, -- { line = 1-based, col = 1-based }
  selection = nil, -- { file, start_line, end_line, mode, text }
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

-- Record the buffer's changedtick when visual mode is entered, stored
-- buffer-locally so concurrent selections in split windows don't clobber each
-- other. capture_selection() compares against it to tell a plain exit (Esc/y)
-- from a destructive one (x/d/c/s/r): if the buffer changed while selecting,
-- the selection was consumed by an operator and no longer exists.
local function mark_visual_enter()
  local buf = vim.api.nvim_get_current_buf()
  if is_real_buffer(buf) then
    vim.b[buf].buoy_visual_tick = vim.api.nvim_buf_get_changedtick(buf)
  end
end

--- Capture the selection when leaving visual mode ('< and '> marks are
--- set at that point). Uses getregion() (nvim 0.10+) for correct
--- charwise/blockwise extraction, falling back to whole lines on older nvim.
---
--- ModeChanged also fires for destructive exits (`x`, `d`, `c`, ...), which
--- delete the selection *before* this runs. We detect those by the buffer's
--- changedtick advancing since visual mode was entered, and clear the cache
--- instead of reading marks that point at text which no longer exists. That
--- guard is version-independent, so neither extraction path below is ever
--- reached with a stale selection.
local function capture_selection()
  local buf = vim.api.nvim_get_current_buf()
  if not is_real_buffer(buf) then
    return
  end

  -- Destructive exit: the selection is gone, so drop it rather than capture.
  local entered_tick = vim.b[buf].buoy_visual_tick
  if entered_tick == nil or vim.api.nvim_buf_get_changedtick(buf) ~= entered_tick then
    M.state.selection = nil
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
    -- No getregion(); whole-line extraction. The changedtick guard above
    -- guarantees the selection still exists, so the marks are in bounds.
    text = table.concat(vim.api.nvim_buf_get_lines(buf, s[2] - 1, e[2], false), "\n")
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
    pattern = "*:[vV\22]*", -- entering visual / V-line / V-block (\22 = Ctrl-V)
    callback = mark_visual_enter,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "[vV\22]*:*", -- leaving visual / V-line / V-block (\22 = Ctrl-V)
    callback = capture_selection,
  })
end

return M
