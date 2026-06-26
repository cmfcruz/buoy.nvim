--- MCP stdio bridge, run by the agent as: nvim -l mcp_bridge.lua
---
--- The agent (Codex or Claude Code) spawns this process per its MCP server
--- config. It speaks MCP JSON-RPC (newline-delimited) on stdio and relays
--- tools/call to the user's *running* Neovim instance over msgpack-RPC.
---
--- Socket discovery, in order:
---   1. $NVIM                 — set automatically for processes spawned from
---                              inside Neovim, if the agent forwards its env
---   2. $NVIM_CONTEXT_SOCKET  — exported by the plugin when launching the agent
---      / $CODEX_NVIM_SOCKET     (legacy alias, same value)
---   3. cwd-keyed lockfile    — written by the plugin on setup()
---   4. "latest" lockfile     — most recently started instance

local function find_socket()
  local env = os.getenv("NVIM")
    or os.getenv("NVIM_CONTEXT_SOCKET")
    or os.getenv("CODEX_NVIM_SOCKET")
  if env and env ~= "" then
    return env
  end

  local dir = vim.fn.stdpath("cache") .. "/buoy"
  local cwd_key = vim.fn.sha256(vim.fn.getcwd()):sub(1, 16)
  for _, name in ipairs({ cwd_key, "latest" }) do
    local f = io.open(dir .. "/" .. name .. ".sock", "r")
    if f then
      local addr = f:read("*a")
      f:close()
      if addr and addr ~= "" then
        return addr
      end
    end
  end
  return nil
end

local socket = find_socket()
local chan = nil
if socket then
  local ok, result = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
  if ok and result ~= 0 then
    chan = result
  end
end

local function respond(id, result, err)
  local msg = { jsonrpc = "2.0", id = id }
  if err then
    msg.error = err
  else
    msg.result = result
  end
  io.write(vim.json.encode(msg) .. "\n")
  io.flush()
end

local function call_nvim(code, args)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, args)
end

local function handle(msg)
  local method, id = msg.method, msg.id

  if method == "initialize" then
    respond(id, {
      protocolVersion = (msg.params and msg.params.protocolVersion) or "2025-03-26",
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = "nvim-context", version = "1.0.0" }, -- x-release-please-version
    })
  elseif method == "notifications/initialized" then
    -- notification: no response
  elseif method == "ping" then
    respond(id, vim.empty_dict())
  elseif method == "tools/list" then
    if not chan then
      return respond(id, { tools = {} })
    end
    local ok, tools = pcall(call_nvim, "return require('buoy.tools').list()", {})
    respond(id, { tools = ok and tools or {} })
  elseif method == "tools/call" then
    if not chan then
      return respond(id, {
        isError = true,
        content = { { type = "text", text = "Bridge could not find a running Neovim instance." } },
      })
    end
    local name = msg.params and msg.params.name
    local args = (msg.params and msg.params.arguments) or vim.empty_dict()
    local ok, result =
      pcall(call_nvim, "return require('buoy.tools').dispatch(...)", { name, args })
    if ok then
      respond(id, {
        content = { { type = "text", text = vim.json.encode(result) } },
      })
    else
      respond(id, {
        isError = true,
        content = { { type = "text", text = "RPC to Neovim failed: " .. tostring(result) } },
      })
    end
  elseif id ~= nil then
    respond(id, nil, { code = -32601, message = "Method not found: " .. tostring(method) })
  end
end

-- Main loop: newline-delimited JSON-RPC on stdin.
while true do
  local line = io.read("*l")
  if line == nil then
    break
  end
  if line ~= "" then
    local ok, msg = pcall(vim.json.decode, line)
    if ok and type(msg) == "table" then
      handle(msg)
    end
  end
end

if chan then
  pcall(vim.fn.chanclose, chan)
end
