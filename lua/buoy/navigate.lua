--- Cursor navigation: move the user's cursor to a location and bring it
--- into view, opening the file if it isn't already on screen. This is the
--- write-side counterpart to context.lua's reads — every other tool only
--- observes; this one acts on the editor.
---
--- Subtlety that drives the whole module: tool handlers run over RPC while
--- the user is typing in the agent, so the *focused* window is its terminal,
--- not an editing window. We must never target window 0 —
--- we pick a real editing window explicitly, skipping the terminal buffer
--- (buftype ~= "") and every floating window (relative ~= "").

local M = {}

local ns = vim.api.nvim_create_namespace("buoy_flash")

local err = require("buoy.error")

--- A "real" editing window: a non-floating window showing a normal buffer.
--- Excludes the agent float, terminals, help, quickfix, etc.
local function is_edit_window(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false -- floating window
  end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

--- Choose the window to navigate in:
---   1. a window already showing the target buffer (avoid a duplicate view)
---   2. the window showing the user's last-edited file (their "active" editor)
---   3. any real editing window
--- Returns (win, already_visible) or (nil, false) if there is no usable
--- editing window at all (e.g. only the agent window is open).
local function pick_window(target_buf, prefer_file)
  -- Only a real editing window counts as "already visible": the target being
  -- shown in a floating window (a preview popup, say) must not make that
  -- float the navigation destination.
  local preferred, fallback
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_edit_window(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if target_buf and target_buf ~= -1 and buf == target_buf then
        return win, true
      end
      if prefer_file and vim.api.nvim_buf_get_name(buf) == prefer_file then
        preferred = preferred or win
      end
      fallback = fallback or win
    end
  end
  return preferred or fallback, false
end

--- Briefly highlight the destination line so the eye catches why the view
--- moved. Non-blocking; the extmark clears itself after ~1.2s.
local function flash(buf, row)
  local id = vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
    line_hl_group = "Visual",
    hl_eol = true,
  })
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
  end, 1200)
end

--- Move the cursor to {file, line, col}, loading the file into an existing
--- editing window if needed. `file` defaults to the user's current file; `col`
--- defaults to 1. Both line and col are 1-based.
--- Returns a structured success or error table.
function M.set_cursor_position(opts)
  local line = opts.line
  if type(line) ~= "number" then
    return err("INVALID_ARGUMENT", "line must be a positive integer.")
  end

  local target = opts.file or require("buoy.context").state.file
  if not target then
    return err("NO_FILE_IN_CONTEXT", "No file argument and no current file in context.")
  end
  target = vim.fn.fnamemodify(target, ":p")

  local buf = vim.fn.bufnr(target)
  local loaded = buf ~= -1 and vim.api.nvim_buf_is_loaded(buf)
  if not loaded and vim.fn.filereadable(target) == 0 then
    return err("FILE_NOT_FOUND", "File is not open and does not exist on disk.")
  end

  local win, already_visible = pick_window(buf, require("buoy.context").state.file)
  if not win then
    return err("NO_EDIT_WINDOW", "No editing window available to navigate in.")
  end

  -- Seed the destination window's jumplist with its current position before
  -- any movement: nvim_win_set_buf and nvim_win_set_cursor record no jump
  -- themselves, and this is what makes a single Ctrl-O reverse the move.
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
  end)

  -- Bring the file into the chosen window if it isn't already shown there.
  -- Reuse the loaded buffer when we can; otherwise load fresh so ftplugins and
  -- LSP attach normally. Neovim still enforces its usual buffer-abandon rules
  -- for the chosen window.
  local opened = false
  if not already_visible then
    if loaded then
      vim.api.nvim_win_set_buf(win, buf)
    else
      vim.api.nvim_win_call(win, function()
        vim.cmd("edit " .. vim.fn.fnameescape(target))
      end)
      buf = vim.api.nvim_win_get_buf(win)
    end
    opened = true
  end

  -- Clamp to the buffer's real extent so an out-of-range guess can't error.
  local row = math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf)))
  local linetext = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local col0 = math.max(0, math.min((opts.col or 1) - 1, #linetext))

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, col0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zvzz") -- open folds, center the line
  end)
  flash(buf, row)

  return {
    kind = "cursor_position",
    file = target,
    line = row,
    col = col0 + 1,
    opened = opened, -- brought a file into a window the user wasn't viewing
    clamped = row ~= line, -- requested line was out of range and was clamped
    hint = opened
        and "Opened the file and moved your cursor. Your previous buffer is still " .. "loaded — Ctrl-O returns to where you were, Ctrl-^ toggles back to it."
      or "Cursor moved. Ctrl-O returns to where you were.",
  }
end

return M
