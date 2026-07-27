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
  local disk_lines = {}
  for line = 1, 14 do
    disk_lines[line] = "line " .. line
  end
  vim.fn.writefile(disk_lines, first_file)

  vim.cmd("cd " .. vim.fn.fnameescape(temp))
  vim.cmd("edit " .. vim.fn.fnameescape(first_file))
  first_file = vim.api.nvim_buf_get_name(0)
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 7, 2 })
  vim.api.nvim_buf_set_lines(0, 6, 7, false, { "unsaved line 7" })

  local context = require("buoy.context")
  context.state.file = first_file
  context.state.filetype = "lua"
  context.state.cursor = { line = 7, col = 3 }
  local tools = require("buoy.tools")
  local range = tools.dispatch("get_buffer_range", {
    start_line = 7,
    end_line = 7,
  })
  eq({ "unsaved line 7" }, range.lines, "targeted reads preserve unsaved contents")

  local namespace = vim.api.nvim_create_namespace("BuoyToolsSpec")
  vim.diagnostic.set(namespace, 0, {
    {
      lnum = 6,
      col = 2,
      severity = vim.diagnostic.severity.WARN,
      message = "test warning",
      source = "tools_spec",
    },
  })
  local diagnostics = tools.dispatch("get_diagnostics", {})
  eq(1, #diagnostics.diagnostics, "diagnostics remain opt-in")
  eq("test warning", diagnostics.diagnostics[1].message, "diagnostic data is unchanged")

  -- Structured, fixed errors.
  eq(
    { kind = "error", code = "INVALID_OPERATION", message = "Unknown operation." },
    tools.dispatch("nope", {}),
    "unknown operations produce a fixed structured error"
  )
  eq(
    "INVALID_ARGUMENT",
    tools.dispatch("get_buffer_range", { start_line = 0, end_line = 3 }).code,
    "non-positive line numbers are rejected"
  )
  eq(
    "INVALID_ARGUMENT",
    tools.dispatch("get_buffer_range", { start_line = 4, end_line = 3 }).code,
    "a reversed line range is rejected"
  )
  eq(
    "INVALID_ARGUMENT",
    tools.dispatch("get_buffer_range", { file = "relative.lua", start_line = 1, end_line = 1 }).code,
    "relative paths are rejected"
  )
  eq(
    { kind = "error", code = "BUFFER_NOT_OPEN", message = "File is not open in Neovim." },
    tools.dispatch(
      "get_buffer_range",
      { file = temp .. "/absent.lua", start_line = 1, end_line = 1 }
    ),
    "reads of unopened files produce a fixed error without echoing the path"
  )
  eq(
    "INVALID_ARGUMENT",
    tools.dispatch("get_diagnostics", { offset = -1 }).code,
    "negative diagnostic offsets are rejected"
  )
  eq(
    "INVALID_ARGUMENT",
    tools.dispatch("get_diagnostics", { unexpected = true }).code,
    "unknown parent-side arguments are rejected"
  )
  eq(
    "INVALID_ARGUMENT",
    tools.dispatch("get_diagnostics", "not an object").code,
    "non-object parent-side arguments are rejected"
  )

  -- Line-count bound and continuation.
  local big_file = temp .. "/big.lua"
  local big_lines = {}
  for line = 1, 620 do
    big_lines[line] = "big line " .. line
  end
  vim.fn.writefile(big_lines, big_file)
  vim.cmd("edit " .. vim.fn.fnameescape(big_file))
  big_file = vim.api.nvim_buf_get_name(0)

  local page = tools.dispatch("get_buffer_range", {
    file = big_file,
    start_line = 1,
    end_line = 620,
  })
  eq(500, #page.lines, "buffer ranges return at most 500 lines")
  eq(500, page.last_line, "last_line reflects the returned page")
  eq(true, page.truncated, "capped ranges are marked truncated")
  eq(501, page.next_start_line, "truncation returns the continuation line")
  local rest = tools.dispatch("get_buffer_range", {
    file = big_file,
    start_line = 501,
    end_line = 620,
  })
  eq(120, #rest.lines, "continuation returns the remaining lines")
  eq(false, rest.truncated, "a complete page is not truncated")

  local beyond = tools.dispatch("get_buffer_range", {
    file = big_file,
    start_line = 9000,
    end_line = 9005,
  })
  eq({}, beyond.lines, "a start beyond EOF succeeds with no lines")
  eq(false, beyond.truncated, "a start beyond EOF is not truncated")

  -- Byte bound: oversized pages shrink with continuation; a single record
  -- that cannot fit is rejected without being echoed.
  local wide_file = temp .. "/wide.lua"
  local wide_lines = {}
  for line = 1, 10 do
    wide_lines[line] = string.rep("x", 5000)
  end
  vim.fn.writefile(wide_lines, wide_file)
  vim.cmd("edit " .. vim.fn.fnameescape(wide_file))
  wide_file = vim.api.nvim_buf_get_name(0)
  local wide =
    tools.dispatch("get_buffer_range", { file = wide_file, start_line = 1, end_line = 10 })
  truthy(#wide.lines >= 1 and #wide.lines < 10, "oversized pages drop trailing lines")
  eq(true, wide.truncated, "byte-bounded pages are marked truncated")
  eq(#wide.lines + 1, wide.next_start_line, "byte-bounded pages return a continuation line")
  truthy(#vim.json.encode(wide) <= 24576, "bounded results stay within the byte limit")

  local huge_file = temp .. "/huge.lua"
  vim.fn.writefile({ string.rep("y", 30000) }, huge_file)
  vim.cmd("edit " .. vim.fn.fnameescape(huge_file))
  huge_file = vim.api.nvim_buf_get_name(0)
  local huge =
    tools.dispatch("get_buffer_range", { file = huge_file, start_line = 1, end_line = 1 })
  eq("OUTPUT_LIMIT", huge.code, "a single unfittable line returns OUTPUT_LIMIT")
  truthy(not vim.json.encode(huge):find("yyyy", 1, true), "the oversized line is not echoed")

  -- Diagnostic record bound, sorting, and offset continuation.
  local many_ns = vim.api.nvim_create_namespace("BuoyToolsSpecMany")
  local many = {}
  for record = 1, 250 do
    many[record] = {
      lnum = 250 - record,
      col = 0,
      severity = vim.diagnostic.severity.INFO,
      message = "diagnostic " .. (250 - record + 1),
      source = "tools_spec",
    }
  end
  vim.diagnostic.set(many_ns, vim.fn.bufnr(big_file), many)
  local first_page = tools.dispatch("get_diagnostics", { file = big_file })
  eq(200, #first_page.diagnostics, "diagnostics return at most 200 records")
  eq(1, first_page.diagnostics[1].line, "diagnostics are sorted by line")
  eq(true, first_page.truncated, "capped diagnostics are marked truncated")
  eq(200, first_page.next_offset, "truncation returns the continuation offset")
  local second_page = tools.dispatch("get_diagnostics", { file = big_file, offset = 200 })
  eq(50, #second_page.diagnostics, "the offset continues where the first page ended")
  eq(201, second_page.diagnostics[1].line, "continuation resumes at the next record")
  eq(false, second_page.truncated, "the final diagnostics page is not truncated")

  -- Capability switches gate the agent-facing read operations. Each defaults on;
  -- disabling one makes dispatch refuse that operation with CAPABILITY_DISABLED
  -- while the others keep working. set_cursor_position is never gated.
  local context_config = require("buoy").config.context

  context_config.expose_buffers = false
  eq(
    "CAPABILITY_DISABLED",
    tools.dispatch("get_buffer_range", { file = big_file, start_line = 1, end_line = 1 }).code,
    "get_buffer_range is refused when expose_buffers is off"
  )
  eq(
    "diagnostics",
    tools.dispatch("get_diagnostics", { file = big_file }).kind,
    "disabling buffers leaves diagnostics working"
  )
  context_config.expose_buffers = true
  eq(
    "buffer_range",
    tools.dispatch("get_buffer_range", { file = big_file, start_line = 1, end_line = 1 }).kind,
    "re-enabling buffers restores the read"
  )

  context_config.expose_diagnostics = false
  eq(
    "CAPABILITY_DISABLED",
    tools.dispatch("get_diagnostics", { file = big_file }).code,
    "get_diagnostics is refused when expose_diagnostics is off"
  )
  eq(
    "buffer_range",
    tools.dispatch("get_buffer_range", { file = big_file, start_line = 1, end_line = 1 }).kind,
    "disabling diagnostics leaves buffer reads working"
  )
  context_config.expose_diagnostics = true

  -- Navigation is never gated: even with both read switches off, dispatch does
  -- not report CAPABILITY_DISABLED for set_cursor_position.
  context_config.expose_buffers = false
  context_config.expose_diagnostics = false
  truthy(
    tools.dispatch("set_cursor_position", { file = big_file, line = 1 }).code
      ~= "CAPABILITY_DISABLED",
    "set_cursor_position is never gated by the expose switches"
  )
  context_config.expose_buffers = true
  context_config.expose_diagnostics = true
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("tools_spec: ok")
