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
  local function run_script(script, mode, env, leave_stdin_open)
    local stdout, exit_code = {}, nil
    local job = vim.fn.jobstart(
      { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script, mode },
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
    if not leave_stdin_open then
      vim.fn.chanclose(job, "stdin")
    end
    truthy(
      vim.wait(10000, function()
        return exit_code ~= nil
      end, 10),
      "child job exits in time"
    )
    return stdout, exit_code
  end

  local bridge = root .. "/bridge/buoy.lua"
  local stdout, code

  -- Leave stdin open for one run of each hook: either would time out if it
  -- tried to consume the agent's event payload.
  stdout, code = run_script(bridge, "hook-context", { NVIM_CONTEXT_SOCKET = addr }, true)
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

  vim.fn.writefile({ "local x = 2" }, file)
  stdout, code = run_script(bridge, "hook-checktime", { NVIM_CONTEXT_SOCKET = addr }, true)
  eq(0, code, "checktime hook exits 0 on success")
  eq({ "" }, stdout, "checktime hook prints nothing")
  truthy(
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "local x = 2"
    end, 10),
    "checktime hook reloads a clean buffer changed outside Neovim"
  )

  local current_buf = vim.api.nvim_get_current_buf()
  local hidden_file = temp .. "/hidden.lua"
  vim.fn.writefile({ "local hidden = 1" }, hidden_file)
  vim.cmd("edit " .. vim.fn.fnameescape(hidden_file))
  local hidden_buf = vim.api.nvim_get_current_buf()
  vim.cmd("buffer " .. current_buf)
  vim.cmd("vnew")
  vim.bo.buftype = "nofile"
  eq({}, vim.fn.win_findbuf(hidden_buf), "hidden buffer is not displayed before refresh")

  vim.fn.writefile({ "local hidden = 2" }, hidden_file)
  stdout, code = run_script(bridge, "hook-checktime", { NVIM_CONTEXT_SOCKET = addr })
  eq(0, code, "checktime hook exits 0 after refreshing a hidden buffer")
  eq({ "" }, stdout, "checktime hook prints nothing after refreshing a hidden buffer")
  truthy(
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(hidden_buf, 0, 1, false)[1] == "local hidden = 2"
    end, 10),
    "checktime hook reloads a clean hidden buffer changed outside Neovim"
  )

  vim.api.nvim_buf_set_lines(hidden_buf, 0, 1, false, { "local hidden = 3" })
  vim.fn.writefile({ "local hidden = 4" }, hidden_file)
  stdout, code = run_script(bridge, "hook-checktime", { NVIM_CONTEXT_SOCKET = addr })
  eq(0, code, "checktime hook exits 0 for a modified hidden buffer")
  eq(
    { "local hidden = 3" },
    vim.api.nvim_buf_get_lines(hidden_buf, 0, 1, false),
    "checktime hook does not reload a hidden buffer with unsaved edits"
  )
  vim.cmd("close")

  local modified_file = temp .. "/modified.lua"
  vim.fn.writefile({ "local x = 1" }, modified_file)
  vim.cmd("edit " .. vim.fn.fnameescape(modified_file))
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local x = 2" })
  vim.fn.writefile({ "local x = 3" }, modified_file)
  stdout, code = run_script(bridge, "hook-checktime", { NVIM_CONTEXT_SOCKET = addr })
  eq(0, code, "checktime hook exits 0 when a buffer has unsaved edits")
  eq({ "" }, stdout, "checktime hook prints nothing when a buffer has unsaved edits")
  eq(
    { "local x = 2" },
    vim.api.nvim_buf_get_lines(0, 0, 1, false),
    "checktime hook does not reload a buffer with unsaved edits"
  )

  -- With no reachable Neovim the hook must print nothing and still exit 0:
  -- Claude Code treats exit 2 as "block the prompt", and any non-zero exit
  -- surfaces error noise. $NVIM is overridden because jobstart() sets it
  -- automatically for children of this test instance.
  local missing = temp .. "/missing.sock"
  stdout, code = run_script(bridge, "hook-context", {
    NVIM = missing,
    NVIM_CONTEXT_SOCKET = missing,
  })
  eq(0, code, "hook exits 0 when no Neovim is reachable")
  eq({ "" }, stdout, "hook prints nothing when no Neovim is reachable")

  stdout, code = run_script(bridge, "hook-checktime", {
    NVIM = missing,
    NVIM_CONTEXT_SOCKET = missing,
  })
  eq(0, code, "checktime hook exits 0 when no Neovim is reachable")
  eq({ "" }, stdout, "checktime hook prints nothing when no Neovim is reachable")

  -- Even an internal transport-load failure keeps both hook contracts
  -- fail-open. Copy only the entry point so its sibling helper is absent.
  local orphan_bridge = temp .. "/buoy.lua"
  vim.fn.writefile(vim.fn.readfile(bridge), orphan_bridge)
  for _, mode in ipairs({ "hook-context", "hook-checktime" }) do
    stdout, code = run_script(orphan_bridge, mode, { NVIM = "", NVIM_CONTEXT_SOCKET = "" })
    eq(0, code, mode .. " exits 0 when the RPC transport cannot load")
    eq({ "" }, stdout, mode .. " stays silent when the RPC transport cannot load")
  end
end, debug.traceback)

vim.fn.delete(temp, "rf")

if not ok then
  error(err)
end

print("hook_spec: ok")
