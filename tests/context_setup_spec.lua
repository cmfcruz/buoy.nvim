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

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")

local ok, err = xpcall(function()
  local context = require("buoy.context")

  -- Case 1: setup() must seed the cache immediately from a real, named buffer,
  -- without waiting for a BufEnter/CursorMoved autocmd to fire.
  local file = temp .. "/seeded.lua"
  vim.fn.writefile({ "line 1", "line 2", "line 3", "line 4" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  file = vim.api.nvim_buf_get_name(0)
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 3, 4 })

  context.state.file = nil
  context.state.filetype = nil
  context.state.cursor = nil

  context.setup()

  eq(file, context.state.file, "setup() seeds state.file from the current real buffer")
  eq("lua", context.state.filetype, "setup() seeds state.filetype from the current real buffer")
  eq(
    { line = 3, col = 5 },
    context.state.cursor,
    "setup() seeds state.cursor from the current real buffer (1-based column)"
  )

  pcall(vim.api.nvim_del_augroup_by_name, "BuoyContext")
  context.state.file = nil
  context.state.filetype = nil
  context.state.cursor = nil

  -- Case 2: an unnamed scratch buffer is not a real buffer, so setup() must
  -- leave the cache untouched (nil).
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(scratch)

  context.setup()

  eq(nil, context.state.file, "setup() leaves state.file nil for a non-real current buffer")
  eq(nil, context.state.filetype, "setup() leaves state.filetype nil for a non-real current buffer")
  eq(nil, context.state.cursor, "setup() leaves state.cursor nil for a non-real current buffer")

  pcall(vim.api.nvim_del_augroup_by_name, "BuoyContext")
  context.state.file = nil
  context.state.filetype = nil
  context.state.cursor = nil
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("context_setup_spec: ok")
