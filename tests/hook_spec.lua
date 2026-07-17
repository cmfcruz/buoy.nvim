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

  local file = temp .. "/current.lua"
  vim.fn.writefile({ "local x = 1" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  file = vim.api.nvim_buf_get_name(0)

  local context = require("buoy.context")
  context.state.file = file
  context.state.filetype = "lua"
  context.state.cursor = { line = 1, col = 1 }

  --- Runs a bridge script as a real headless child while this instance keeps
  --- serving RPC (vim.wait pumps the main loop), mirroring how the agent
  --- spawns the hook in production.
  local function run_script(script, env)
    local stdout, exit_code = {}, nil
    local job = vim.fn.jobstart(
      { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script },
      {
        env = env,
        stdout_buffered = true,
        on_stdout = function(_, data)
          stdout = data
        end,
        on_exit = function(_, code)
          exit_code = code
        end,
      }
    )
    truthy(job > 0, "child job starts")
    vim.fn.chanclose(job, "stdin")
    truthy(
      vim.wait(10000, function()
        return exit_code ~= nil
      end, 10),
      "child job exits in time"
    )
    return stdout, exit_code
  end

  local hook = root .. "/bridge/context_hook.lua"
  local stdout, code

  stdout, code = run_script(hook, { NVIM_CONTEXT_SOCKET = addr })
  eq(0, code, "hook exits 0 on success")
  eq(
    "Current Neovim editor context (auto-refreshed for every prompt):",
    stdout[1],
    "hook output starts with a readable header"
  )
  local snapshot = vim.json.decode(stdout[2])
  eq(vim.fn.getcwd(), snapshot.cwd, "snapshot carries the cwd")
  eq(file, snapshot.current.file, "snapshot carries the current file")
  eq({ line = 1, col = 1 }, snapshot.current.cursor, "snapshot carries the cursor")

  -- With no reachable Neovim the hook must print nothing and still exit 0:
  -- Claude Code treats exit 2 as "block the prompt", and any non-zero exit
  -- surfaces error noise. $NVIM is overridden because jobstart() sets it
  -- automatically for children of this test instance.
  local missing = temp .. "/missing.sock"
  stdout, code = run_script(hook, {
    NVIM = missing,
    NVIM_CONTEXT_SOCKET = missing,
  })
  eq(0, code, "hook exits 0 when no Neovim is reachable")
  eq({ "" }, stdout, "hook prints nothing when no Neovim is reachable")
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("hook_spec: ok")
