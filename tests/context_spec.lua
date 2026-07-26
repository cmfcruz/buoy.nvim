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

local original_visualmode = vim.fn.visualmode

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
  local expected_cwd = vim.fn.getcwd()
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
  vim.fn.visualmode = function()
    return "v"
  end
  vim.fn.setpos("'<", { 0, 7, 3, 0 })
  vim.fn.setpos("'>", { 0, 7, 8, 0 })
  context.capture_command_selection(7, 7)
  vim.fn.visualmode = original_visualmode
  eq({
    file = first_file,
    start_line = 7,
    end_line = 7,
    start_col = 3,
    end_col = 8,
    mode = "v",
    text = "saved ",
  }, context.state.selection, "command range preserves the exact visual handoff")

  local tools = require("buoy.tools")
  local snapshot = tools.editor_context()
  eq(expected_cwd, snapshot.cwd, "cwd is included")
  eq({
    file = first_file,
    filetype = "lua",
    cursor = { line = 7, col = 3 },
  }, snapshot.current, "current editor context has the expected shape")
  eq(context.state.selection, snapshot.selection, "exact active selection is included")

  context.capture_command_selection(8, 9)
  eq({
    file = first_file,
    start_line = 8,
    end_line = 9,
    start_col = 1,
    end_col = 6,
    mode = "V",
    text = "line 8\nline 9",
  }, context.state.selection, "an explicit command range becomes a linewise handoff")

  local by_file = {}
  for _, buffer in ipairs(snapshot.buffers) do
    by_file[buffer.file] = buffer
  end
  truthy(by_file[first_file], "current buffer is listed")
  truthy(by_file[first_file].modified, "current buffer modification flag is true")
  truthy(by_file[second_file], "other open buffer is listed")
  eq(false, by_file[second_file].modified, "other buffer modification flag is false")

  context.state.file = nil
  context.state.filetype = nil
  context.state.cursor = nil
  context.clear_selection()
  local unavailable = tools.editor_context()
  eq(expected_cwd, unavailable.cwd, "cwd survives missing current-file context")
  truthy(type(unavailable.buffers) == "table", "buffers remains an array-like table")
  eq({
    file = vim.NIL,
    filetype = vim.NIL,
    cursor = vim.NIL,
  }, unavailable.current, "missing current editor context has the expected shape")
  eq(vim.NIL, unavailable.selection, "inactive selection is null")

  local encoded = vim.json.encode(unavailable)
  truthy(encoded:find('"selection":null', 1, true), "selection JSON value is null")
  truthy(encoded:find('"file":null', 1, true), "current file JSON value is null")
  truthy(encoded:find('"buffers":[', 1, true), "buffers JSON value is an array")
end, debug.traceback)

vim.fn.visualmode = original_visualmode
vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("context_spec: ok")
