local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local function fail(message)
  error(message, 2)
end

local function eq(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    fail(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        label or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function truthy(value, label)
  if not value then
    fail(label or "expected a truthy value")
  end
end

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")

local ok, err = xpcall(function()
  local first_file = temp .. "/main.lua"
  local second_file = temp .. "/other.lua"
  local disk_lines = {}
  for line = 1, 14 do
    disk_lines[line] = "line " .. line
  end
  vim.fn.writefile(disk_lines, first_file)
  vim.fn.writefile({ "other" }, second_file)

  vim.cmd("cd " .. vim.fn.fnameescape(temp))
  vim.cmd("edit " .. vim.fn.fnameescape(first_file))
  first_file = vim.api.nvim_buf_get_name(0)
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 7, 2 })
  vim.api.nvim_buf_set_lines(0, 6, 7, false, { "unsaved line 7" })
  vim.cmd("badd " .. vim.fn.fnameescape(second_file))
  second_file = vim.api.nvim_buf_get_name(vim.fn.bufnr(second_file))

  local context = require("buoy.context")
  context.state.file = first_file
  context.state.filetype = "lua"
  context.state.cursor = { line = 7, col = 3 }
  local tools = require("buoy.tools")
  local moved = tools.dispatch("set_cursor_position", { line = 3, col = 2 })
  eq(first_file, moved.file, "cursor navigation defaults to the context file")
  eq({ 3, 1 }, vim.api.nvim_win_get_cursor(0), "cursor navigation remains 1-based")
  -- The agent reads the destination back out of the result, so the reported
  -- position must be 1-based too, not the 0-based column the API took.
  eq(3, moved.line, "the result reports the 1-based destination line")
  eq(2, moved.col, "the result reports the 1-based destination column")

  -- A larger loaded buffer is the target for window and jumplist checks.
  local big_file = temp .. "/big.lua"
  local big_lines = {}
  for line = 1, 620 do
    big_lines[line] = "big line " .. line
  end
  vim.fn.writefile(big_lines, big_file)
  vim.cmd("edit " .. vim.fn.fnameescape(big_file))
  big_file = vim.api.nvim_buf_get_name(0)

  -- A loaded named buffer is navigable before its first write to disk.
  local unsaved_file = temp .. "/never_written.lua"
  vim.cmd("edit " .. vim.fn.fnameescape(unsaved_file))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
  unsaved_file = vim.api.nvim_buf_get_name(0)
  local unsaved_nav = tools.dispatch("set_cursor_position", { file = unsaved_file, line = 2 })
  eq("cursor_position", unsaved_nav.kind, "unsaved named buffers are navigable")
  eq(2, unsaved_nav.line, "navigation reaches the requested line")

  -- A target visible only in a floating window is not a navigation target.
  local float_buf = vim.fn.bufadd(big_file)
  vim.fn.bufload(float_buf)
  local float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 20,
    height = 5,
  })
  vim.bo.modified = false
  local float_nav = tools.dispatch("set_cursor_position", { file = big_file, line = 4 })
  eq("cursor_position", float_nav.kind, "navigation succeeds despite the float")
  truthy(
    vim.api.nvim_get_current_win() ~= float_win,
    "the floating window is never the destination"
  )
  eq(
    "",
    vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative,
    "navigation lands in a real editing window"
  )
  eq(float_buf, vim.api.nvim_get_current_buf(), "the real window now shows the target buffer")
  vim.api.nvim_win_close(float_win, true)

  -- One Ctrl-O reverses same-buffer navigation in the destination window.
  local jump_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(jump_win, { 7, 0 })
  local same_buffer_jump =
    tools.dispatch("set_cursor_position", { file = big_file, line = 10, col = 2 })
  eq("cursor_position", same_buffer_jump.kind, "same-buffer navigation succeeds")
  eq({ 10, 1 }, vim.api.nvim_win_get_cursor(jump_win), "same-buffer navigation moves")
  vim.cmd([[execute "normal! \<C-o>"]])
  eq({ 7, 0 }, vim.api.nvim_win_get_cursor(jump_win), "one Ctrl-O restores the prior cursor")

  -- Cross-buffer navigation is reversible through the same destination window.
  local jump = tools.dispatch("set_cursor_position", { file = second_file, line = 1 })
  eq("cursor_position", jump.kind, "cross-buffer navigation succeeds")
  eq(second_file, vim.api.nvim_buf_get_name(0), "navigation switched to the target buffer")
  vim.cmd([[execute "normal! \<C-o>"]])
  eq(big_file, vim.api.nvim_buf_get_name(0), "one Ctrl-O returns to the previous buffer")
  eq({ 7, 0 }, vim.api.nvim_win_get_cursor(jump_win), "one Ctrl-O restores the previous position")
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("navigate_spec: ok")
