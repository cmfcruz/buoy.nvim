--- Tracks editor context (file, cursor, active handoff selection) from
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

-- Namespace for the persistent selection highlight (see paint_selection).
local ns = vim.api.nvim_create_namespace("BuoyContextSelection")
-- Buffer that currently holds the painted highlight, so we can clear it.
local highlighted_buf = nil
-- Buffer of the cached selection, kept out of M.state.selection (which the MCP
-- server serves verbatim) so the agent isn't handed an internal buffer number.
local selection_buf = nil
-- Ordered getpos()-style start/end positions of the cached selection, kept for
-- repainting the exact charwise/blockwise region (M.state.selection only carries
-- the normalized line/column numbers the MCP exposes).
local selection_pos = nil
-- Pressing the agent toggle from visual mode is an explicit selection handoff.
-- The following visual-mode exit should not clear the just-captured selection.
local preserve_next_visual_exit = false

local function is_real_buffer(buf)
  return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

--- Leaving visual mode (or switching to the agent window) ends visual mode and
--- drops Neovim's live Visual highlight. To keep the selection visible while the
--- user is in the floating AI client, we repaint the captured range ourselves as
--- whole-line extmarks. Cleared on a new selection or when the cache is dropped.
local function clear_selection_highlight()
  if highlighted_buf and vim.api.nvim_buf_is_valid(highlighted_buf) then
    vim.api.nvim_buf_clear_namespace(highlighted_buf, ns, 0, -1)
  end
  highlighted_buf = nil
end

local function clear_selection()
  M.state.selection = nil
  selection_buf = nil
  selection_pos = nil
  preserve_next_visual_exit = false
  clear_selection_highlight()
end

M.clear_selection = clear_selection

local function line_byte_len(buf, row)
  return #(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
end

-- Build the handoff selection from two getpos()-style positions and a visual mode
-- char ("v"/"V"/Ctrl-V). Orders the positions, extracts the exact text with
-- getregion() (nvim 0.10+, whole lines otherwise), and records the buffer
-- separately from M.state.selection so the MCP-served payload stays buffer-free.
--
-- start_col/end_col are 1-based, inclusive byte columns so the agent can locate
-- a sub-line selection precisely. Linewise (V) selections span whole lines, and
-- their '>' column is the v:maxcol sentinel, so we normalize those to col 1
-- through the end line's length rather than leak the sentinel.
local function set_selection(buf, p1, p2, vmode)
  local s, e = p1, p2
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end

  local text
  if vim.fn.has("nvim-0.10") == 1 then
    text = table.concat(vim.fn.getregion(s, e, { type = vmode }), "\n")
  else
    text = table.concat(vim.api.nvim_buf_get_lines(buf, s[2] - 1, e[2], false), "\n")
  end

  local start_col, end_col
  if vmode == "V" then
    start_col = 1
    end_col = math.max(line_byte_len(buf, e[2]), 1)
  else
    start_col = s[3]
    end_col = math.min(e[3], math.max(line_byte_len(buf, e[2]), 1))
  end

  M.state.selection = {
    file = vim.api.nvim_buf_get_name(buf),
    start_line = s[2],
    end_line = e[2],
    start_col = start_col,
    end_col = end_col,
    mode = vmode,
    text = text,
  }
  selection_buf = buf
  selection_pos = { s, e }
end

local function in_visual_mode()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
end

-- Paint the handoff selection so it stays visible while focus is in the agent
-- popup. Called when the agent opens (F2), not on every visual exit, so Esc and
-- yanks dismiss the selection instead of leaving stale agent context behind.
--
-- When F2 is pressed from visual mode the '< / '> marks aren't set yet and the
-- ModeChanged exit may not have run, so we read the live selection straight
-- from the visual anchor ('v') and cursor ('.') and refresh the cache here.
function M.paint_selection()
  if in_visual_mode() then
    local buf = vim.api.nvim_get_current_buf()
    if is_real_buffer(buf) then
      set_selection(buf, vim.fn.getpos("v"), vim.fn.getpos("."), vim.fn.mode())
      preserve_next_visual_exit = true
    end
  end

  clear_selection_highlight()
  local sel = M.state.selection
  if not sel then
    return
  end
  if not (selection_buf and vim.api.nvim_buf_is_valid(selection_buf)) then
    clear_selection()
    return
  end

  if sel.mode == "V" or not selection_pos or vim.fn.has("nvim-0.10") == 0 then
    -- Linewise (or no getregionpos): whole lines, including past the last
    -- character (hl_eol), matching what linewise visual mode shows.
    for row = sel.start_line, sel.end_line do
      vim.api.nvim_buf_set_extmark(selection_buf, ns, row - 1, 0, {
        line_hl_group = "Visual",
        hl_eol = true,
      })
    end
  else
    -- Charwise / blockwise: highlight the exact columns. getregionpos() returns
    -- one {start_pos, end_pos} segment per line, with 1-based byte columns and an
    -- inclusive end; the inclusive 1-based end maps straight to the exclusive
    -- 0-based extmark end_col (+off for selections reaching past EOL). Clamp to
    -- the line so set_extmark can't error on an out-of-range column.
    for _, seg in
      ipairs(vim.fn.getregionpos(selection_pos[1], selection_pos[2], { type = sel.mode }))
    do
      local p1, p2 = seg[1], seg[2]
      local row = p2[2]
      local len = #(vim.api.nvim_buf_get_lines(selection_buf, row - 1, row, false)[1] or "")
      vim.api.nvim_buf_set_extmark(selection_buf, ns, p1[2] - 1, p1[3] - 1, {
        end_row = row - 1,
        end_col = math.min(p2[3] + p2[4], len),
        hl_group = "Visual",
      })
    end
  end

  highlighted_buf = selection_buf
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

-- A new visual selection supersedes any previous handoff selection.
local function mark_visual_enter()
  local buf = vim.api.nvim_get_current_buf()
  if is_real_buffer(buf) then
    clear_selection()
  end
end

--- Leaving visual mode by Esc, yank, or an edit means the user has dismissed the
--- selection. Keep it only for the explicit visual-mode F2 handoff path, where
--- paint_selection() captured the live range before focus moved to the agent.
local function clear_dismissed_selection()
  if preserve_next_visual_exit then
    preserve_next_visual_exit = false
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  if not is_real_buffer(buf) then
    return
  end

  clear_selection()
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
    callback = clear_dismissed_selection,
  })
end

return M
