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

local function fake_transport()
  local transport = {
    writes = {},
    cleanups = 0,
  }

  function transport:on_exit(callback)
    self.exit_callback = callback
  end

  function transport:on_timeout(_, callback)
    self.timeout_callback = callback
  end

  function transport:on_data(callback)
    self.data_callback = callback
  end

  function transport:write(data)
    self.writes[#self.writes + 1] = vim.json.decode(data)
  end

  function transport:cleanup()
    self.cleanups = self.cleanups + 1
  end

  return transport
end

local function run_protocol()
  local transport = fake_transport()
  local calls = {}
  require("buoy.custom.codex_protocol")(transport, "/work/tree", function(err, value)
    calls[#calls + 1] = { err = err, value = value }
  end, 25)
  return transport, calls
end

local ok, err = xpcall(function()
  local transport, calls = run_protocol()
  eq("initialize", transport.writes[1].method, "initialization is sent first")
  transport.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
  eq("initialized", transport.writes[2].method, "initialization is acknowledged")
  eq("config/read", transport.writes[3].method, "effective config is requested")
  eq(
    { cwd = "/work/tree", includeLayers = false },
    transport.writes[3].params,
    "config resolution uses Neovim's cwd"
  )
  transport.data_callback(vim.json.encode({
    id = 2,
    result = { config = { developer_instructions = "keep me" } },
  }) .. "\n")
  eq({ { value = "keep me" } }, calls, "effective developer instructions are extracted")
  eq(1, transport.cleanups, "successful resolution cleans up")

  for _, value in ipairs({ "", vim.NIL }) do
    transport, calls = run_protocol()
    transport.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
    transport.data_callback(vim.json.encode({
      id = 2,
      result = { config = { developer_instructions = value } },
    }) .. "\n")
    local expected = value == vim.NIL and nil or value
    eq(expected, calls[1].value, "empty and null instructions are accepted")
    eq(1, transport.cleanups, "empty and null responses clean up")
  end

  local failures = {
    function(t)
      t.data_callback("{nope}\n")
    end,
    function(t)
      t.data_callback(vim.json.encode({ id = 1, error = { message = "no" } }) .. "\n")
    end,
    function(t)
      t.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
      t.data_callback(vim.json.encode({ id = 2, error = { message = "no" } }) .. "\n")
    end,
    function(t)
      t.data_callback(vim.json.encode({ id = 1, result = {} }) .. "\n")
      t.data_callback(vim.json.encode({ id = 2, result = {} }) .. "\n")
    end,
    function(t)
      t.exit_callback()
    end,
    function(t)
      t.timeout_callback()
    end,
  }
  for _, trigger in ipairs(failures) do
    transport, calls = run_protocol()
    trigger(transport)
    truthy(calls[1].err, "failure returns an error")
    eq(1, #calls, "failure callback runs exactly once")
    eq(1, transport.cleanups, "failure cleans up")
    transport.exit_callback()
    eq(1, #calls, "late process exit does not call back again")
  end

  local codex = require("buoy.custom.codex")
  local instructions = require("buoy.instructions")
  local opts = { cmd = "codex-custom", cwd = "/work/tree", context = {} }
  local developer_instructions = "existing guidance\n\twith controls"
  local argv = codex.argv(opts, developer_instructions)
  eq("codex-custom", argv[1], "Codex preserves the configured command")
  eq("-c", argv[2], "Codex attaches its developer-instructions override")
  local encoded = argv[3]:sub(#"developer_instructions=" + 1)
  eq(
    developer_instructions,
    vim.json.decode(encoded),
    "Codex safely renders multiline developer instructions as TOML"
  )
  eq("-c", argv[4], "Codex attaches its prompt hook")
  truthy(argv[5]:find("hooks.UserPromptSubmit", 1, true), "Codex maps prompt submission")
  eq("-c", argv[6], "Codex attaches its refresh hook")
  truthy(argv[7]:find('matcher="Edit|Write"', 1, true), "Codex matches native mutations")

  opts.context = { expose_editor_context = false }
  eq(
    { "codex-custom" },
    codex.argv(opts, nil),
    "Codex omits disabled hooks and an absent instruction override"
  )
  opts.context = {}

  local original_resolve = codex.resolve_instructions
  local original_notify = vim.notify
  local notifications = {}
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message, level }
  end

  codex.resolve_instructions = function(cmd, cwd, callback)
    eq("codex-custom", cmd, "Codex config resolution uses the configured command")
    eq("/work/tree", cwd, "Codex config resolution uses the launch cwd")
    callback(nil, "existing guidance")
  end
  local resolved
  codex.resolve(opts, function(value)
    resolved = value
  end)
  local resolved_instructions = resolved[3]:sub(#"developer_instructions=" + 1)
  eq(
    "existing guidance\n\n" .. instructions.neovim_instructions(),
    vim.json.decode(resolved_instructions),
    "Codex preserves effective instructions before appending shared guidance"
  )
  eq(0, #notifications, "successful Codex resolution stays quiet")

  codex.resolve_instructions = function(_, _, callback)
    callback("unsupported API")
  end
  codex.resolve(opts, function(value)
    resolved = value
  end)
  eq("-c", resolved[2], "degraded Codex keeps its prompt hook")
  truthy(
    resolved[3]:find("hooks.UserPromptSubmit", 1, true),
    "degraded Codex keeps automatic context"
  )
  eq(1, #notifications, "degraded Codex warns once")
  truthy(
    notifications[1][1]:find("on%-demand live editor operations are unavailable"),
    "degraded Codex explains the unavailable surface"
  )
  codex.resolve_instructions = original_resolve
  vim.notify = original_notify
end, debug.traceback)

if not ok then
  error(err)
end

print("codex_spec: ok")
