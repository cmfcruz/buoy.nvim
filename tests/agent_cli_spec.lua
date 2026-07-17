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
  local addr = vim.fn.serverstart()
  truthy(addr and addr ~= "", "test instance exposes an RPC socket")

  -- A directory with a space exercises path handling end to end.
  local spaced_dir = temp .. "/with space"
  vim.fn.mkdir(spaced_dir, "p")
  local file = spaced_dir .. "/current.lua"
  vim.fn.writefile({ "local x = 1", "local y = 2", "local z = 3" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  file = vim.api.nvim_buf_get_name(0)
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local x = 'unsaved'" })

  local context = require("buoy.context")
  context.state.file = file
  context.state.filetype = "lua"
  context.state.cursor = { line = 1, col = 1 }

  local cli = root .. "/bridge/agent_cli.lua"

  --- Runs the CLI exactly as the agent's shell tool would: a headless child
  --- with the operation at arg[1], while this instance keeps serving RPC
  --- (vim.wait pumps the main loop).
  local function run_cli(cli_args, env)
    local argv = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", cli }
    vim.list_extend(argv, cli_args)
    local stdout, exit_code = {}, nil
    local job = vim.fn.jobstart(argv, {
      env = env or { NVIM_CONTEXT_SOCKET = addr },
      stdout_buffered = true,
      on_stdout = function(_, data)
        stdout = data
      end,
      on_exit = function(_, code)
        exit_code = code
      end,
    })
    truthy(job > 0, "CLI child starts")
    vim.fn.chanclose(job, "stdin")
    truthy(
      vim.wait(10000, function()
        return exit_code ~= nil
      end, 10),
      "CLI child exits in time"
    )
    return stdout, exit_code
  end

  --- Asserts stdout is exactly one JSON object plus a trailing newline.
  local function decode_single(stdout)
    eq(2, #stdout, "stdout is a single newline-terminated line")
    eq("", stdout[2], "nothing follows the JSON object")
    return vim.json.decode(stdout[1])
  end

  local stdout, code = run_cli({ "get_buffer_range", "--start-line", "1", "--end-line", "2" })
  eq(0, code, "get_buffer_range exits 0")
  local range = decode_single(stdout)
  eq("buffer_range", range.kind, "buffer range result is labeled")
  eq({ "local x = 'unsaved'", "local y = 2" }, range.lines, "reads reflect unsaved edits")
  eq(false, range.truncated, "small ranges are not truncated")

  stdout, code =
    run_cli({ "get_buffer_range", "--start-line", "3", "--end-line", "3", "--file", file })
  eq(0, code, "explicit --file with a space in the path works")
  eq({ "local z = 3" }, decode_single(stdout).lines, "explicit file reads target the right buffer")

  local namespace = vim.api.nvim_create_namespace("BuoyAgentCliSpec")
  vim.diagnostic.set(namespace, 0, {
    {
      lnum = 1,
      col = 2,
      severity = vim.diagnostic.severity.ERROR,
      message = "cli test error",
      source = "agent_cli_spec",
    },
  })
  stdout, code = run_cli({ "get_diagnostics", "--file", file })
  eq(0, code, "get_diagnostics exits 0")
  local diagnostics = decode_single(stdout)
  eq(1, #diagnostics.diagnostics, "diagnostics arrive over the CLI")
  eq(
    "cli test error",
    diagnostics.diagnostics[1].message,
    "diagnostic fields survive the round trip"
  )

  stdout, code = run_cli({ "set_cursor_position", "--line", "2", "--col", "3" })
  eq(0, code, "set_cursor_position exits 0")
  eq("cursor_position", decode_single(stdout).kind, "navigation result is labeled")
  eq({ 2, 2 }, vim.api.nvim_win_get_cursor(0), "the CLI moved the live cursor")

  -- Invalid input: dispatch errors remain one JSON error with exit class 2.
  stdout, code = run_cli({ "frobnicate" })
  eq(2, code, "unknown operations exit 2")
  eq("INVALID_OPERATION", decode_single(stdout).code, "unknown operations report INVALID_OPERATION")

  stdout, code = run_cli({ "get_buffer_range" })
  eq(2, code, "semantic validation errors exit 2")
  eq(
    "start_line and end_line must be positive integers.",
    decode_single(stdout).message,
    "semantic validation errors reach the CLI unchanged"
  )

  -- Editor rejection: exit class 4.
  stdout, code = run_cli({
    "get_buffer_range",
    "--start-line",
    "1",
    "--end-line",
    "1",
    "--file",
    temp .. "/absent.lua",
  })
  eq(4, code, "an unopened file exits 4")
  local rejected = decode_single(stdout)
  eq("BUFFER_NOT_OPEN", rejected.code, "unopened files report BUFFER_NOT_OPEN")
  eq("get_buffer_range", rejected.operation, "editor errors name the parsed operation")

  local tools = require("buoy.tools")
  local dispatch = tools.dispatch
  tools.dispatch = function()
    return "invalid result"
  end
  stdout, code = run_cli({ "get_diagnostics" })
  tools.dispatch = dispatch
  eq(70, code, "a malformed editor result exits 70")
  eq("INTERNAL", decode_single(stdout).code, "a malformed editor result reports INTERNAL")

  -- Output limit: the oversized record is rejected, not echoed.
  local huge_file = temp .. "/huge.lua"
  vim.fn.writefile({ string.rep("y", 30000) }, huge_file)
  vim.cmd("badd " .. vim.fn.fnameescape(huge_file))
  vim.fn.bufload(vim.fn.bufnr(vim.fn.fnamemodify(huge_file, ":p")))
  huge_file = vim.fn.fnamemodify(huge_file, ":p")
  stdout, code =
    run_cli({ "get_buffer_range", "--start-line", "1", "--end-line", "1", "--file", huge_file })
  eq(4, code, "an oversized record exits 4")
  eq("OUTPUT_LIMIT", decode_single(stdout).code, "oversized records report OUTPUT_LIMIT")
  truthy(not stdout[1]:find("yyyy", 1, true), "the oversized record is not echoed")

  -- Socket routing: an explicit stale socket never falls through to $NVIM,
  -- and with neither variable there is no editor to reach. jobstart() sets
  -- $NVIM automatically for children of this test instance, so both cases
  -- must override it explicitly.
  local missing = temp .. "/missing.sock"
  stdout, code = run_cli({ "get_diagnostics" }, { NVIM = addr, NVIM_CONTEXT_SOCKET = missing })
  eq(3, code, "an explicit stale socket exits 3 without falling through")
  eq("RPC_FAILED", decode_single(stdout).code, "a stale socket reports RPC_FAILED")

  stdout, code = run_cli({ "get_diagnostics" }, { NVIM = "", NVIM_CONTEXT_SOCKET = "" })
  eq(3, code, "missing socket variables exit 3")
  eq(
    "NVIM_UNAVAILABLE",
    decode_single(stdout).code,
    "missing socket variables report NVIM_UNAVAILABLE"
  )
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("agent_cli_spec: ok")
