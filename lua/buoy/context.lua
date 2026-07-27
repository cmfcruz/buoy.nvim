--- Tracks editor context (file, cursor, active handoff selection) from
--- *real* buffers. This cache is what the agent CLI reads, because when
--- the user is typing in the agent terminal, the "current" window is the
--- terminal — the interesting context is wherever they were editing.

local M = {}

-- The active selection handoff owns its agent-facing payload and all editor-only
-- state needed to preserve and repaint it. M.state.selection exposes only payload.
local selection_handoff = nil
local clear_selection

M.state = setmetatable({
  file = nil, -- absolute path of last real file buffer
  filetype = nil,
  cursor = nil, -- { line = 1-based, col = 1-based }
}, {
  __index = function(_, key)
    if key == "selection" then
      return selection_handoff and selection_handoff.payload
    end
  end,
  __newindex = function(state, key, _)
    if key == "selection" then
      clear_selection()
      return
    end
    rawset(state, key, _)
  end,
})

-- Namespace for the persistent selection highlight (see paint_selection).
local ns = vim.api.nvim_create_namespace("BuoyContextSelection")

local function is_real_buffer(buf)
  return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

--- Clear any extmarks from the previously painted handoff selection.
local function clear_selection_highlight()
  local highlighted_buf = selection_handoff and selection_handoff.highlighted_buf
  if highlighted_buf and vim.api.nvim_buf_is_valid(highlighted_buf) then
    vim.api.nvim_buf_clear_namespace(highlighted_buf, ns, 0, -1)
  end
  if selection_handoff then
    selection_handoff.highlighted_buf = nil
  end
end

clear_selection = function()
  clear_selection_highlight()
  selection_handoff = nil
end

M.clear_selection = clear_selection

local function line_byte_len(buf, row)
  return #(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
end

-- Build the handoff selection from two getpos()-style positions and a visual mode
-- char ("v"/"V"/Ctrl-V). Orders the positions, extracts the exact text with
-- getregion(), and records editor-only details beside the payload so the agent
-- is not handed internal buffer state.
--
-- start_col/end_col are 1-based, inclusive byte columns so the agent can locate
-- a sub-line selection precisely. Linewise (V) selections span whole lines, and
-- their marks can use the v:maxcol sentinel, so we normalize those to col 1
-- through the end line's length.
local function set_selection(buf, p1, p2, vmode)
  local s, e = p1, p2
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end

  local text = table.concat(vim.fn.getregion(s, e, { type = vmode }), "\n")

  local start_col, end_col
  if vmode == "V" then
    start_col = 1
    end_col = math.max(line_byte_len(buf, e[2]), 1)
  else
    start_col = s[3]
    end_col = math.min(e[3], math.max(line_byte_len(buf, e[2]), 1))
  end

  selection_handoff = {
    payload = {
      file = vim.api.nvim_buf_get_name(buf),
      start_line = s[2],
      end_line = e[2],
      start_col = start_col,
      end_col = end_col,
      mode = vmode,
      text = text,
    },
    buf = buf,
    pos = { s, e },
    highlighted_buf = selection_handoff and selection_handoff.highlighted_buf,
    preserve_next_visual_exit = false,
  }
end

local function in_visual_mode()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
end

--- Capture the range passed to an Ex command as an explicit selection handoff.
--- Visual-mode `:` commands run after Neovim has returned to Normal mode, but
--- the exact `'<` and `'>` marks and visual mode are still available. If those marks
--- do not match the supplied lines (for example, `:2,5Buoy` typed directly),
--- treat the command range as a linewise handoff instead of reusing stale marks.
function M.capture_command_selection(first_line, last_line)
  local buf = vim.api.nvim_get_current_buf()
  if not is_real_buffer(buf) then
    return
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local vmode = vim.fn.visualmode()
  local marks_match = start_pos[2] == first_line
    and end_pos[2] == last_line
    and (vmode == "v" or vmode == "V" or vmode == "\22")

  if not marks_match then
    start_pos = { 0, first_line, 1, 0 }
    end_pos = { 0, last_line, math.max(line_byte_len(buf, last_line), 1), 0 }
    vmode = "V"
  end

  set_selection(buf, start_pos, end_pos, vmode)
end

-- Paint the handoff selection so it stays visible while focus is in the agent.
-- Called when the agent window opens, not on every visual exit, so Esc and yanks
-- dismiss the selection instead of leaving stale agent context behind.
--
-- When the agent opens from visual mode the `'<` and `'>` marks aren't set yet and
-- the ModeChanged exit may not have run, so we read the live selection straight
-- from the visual anchor ('v') and cursor ('.') and refresh the cache here.
function M.paint_selection()
  if in_visual_mode() then
    local buf = vim.api.nvim_get_current_buf()
    if is_real_buffer(buf) then
      set_selection(buf, vim.fn.getpos("v"), vim.fn.getpos("."), vim.fn.mode())
      selection_handoff.preserve_next_visual_exit = true
    end
  end

  clear_selection_highlight()
  local handoff = selection_handoff
  if not handoff then
    return
  end
  if not vim.api.nvim_buf_is_valid(handoff.buf) then
    clear_selection()
    return
  end

  local sel = handoff.payload
  if sel.mode == "V" then
    -- Linewise: whole lines, including past the last character (hl_eol),
    -- matching what linewise visual mode shows.
    for row = sel.start_line, sel.end_line do
      vim.api.nvim_buf_set_extmark(handoff.buf, ns, row - 1, 0, {
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
    for _, seg in ipairs(vim.fn.getregionpos(handoff.pos[1], handoff.pos[2], { type = sel.mode })) do
      local p1, p2 = seg[1], seg[2]
      local row = p2[2]
      local len = #(vim.api.nvim_buf_get_lines(handoff.buf, row - 1, row, false)[1] or "")
      vim.api.nvim_buf_set_extmark(handoff.buf, ns, p1[2] - 1, p1[3] - 1, {
        end_row = row - 1,
        end_col = math.min(p2[3] + p2[4], len),
        hl_group = "Visual",
      })
    end
  end

  handoff.highlighted_buf = handoff.buf
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
--- selection. Keep it only for the explicit visual-mode agent handoff path, where
--- paint_selection() captured the live range before focus moved to the agent.
local function clear_dismissed_selection()
  if selection_handoff and selection_handoff.preserve_next_visual_exit then
    selection_handoff.preserve_next_visual_exit = false
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

  update_position()
end

return M
