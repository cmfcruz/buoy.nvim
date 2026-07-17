--- Shared Neovim discovery and RPC helpers for the bridge scripts.
--- Loaded with dofile() from context_hook.lua and agent_cli.lua so the
--- standalone scripts can share this sibling without relying on runtimepath.
---
--- Socket discovery, in order:
---   1. $NVIM_CONTEXT_SOCKET  — exported by the plugin when launching the
---                              agent; authoritative when set, with no
---                              fall-through to another Neovim
---   2. $NVIM                 — inherited by descendants of processes spawned
---                              inside Neovim; used only without an explicit socket

local M = {}

local function find_socket()
  local explicit = os.getenv("NVIM_CONTEXT_SOCKET")
  if explicit and explicit ~= "" then
    return explicit
  end
  local inherited = os.getenv("NVIM")
  if inherited and inherited ~= "" then
    return inherited
  end
  return nil
end

--- Connect to the discovered instance; returns an RPC channel id or nil plus
--- a stable error code. Connection failures do not expose the socket path or
--- fall through to another candidate.
function M.connect()
  local socket = find_socket()
  if not socket then
    return nil, "NVIM_UNAVAILABLE"
  end
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
  if ok and chan ~= 0 then
    return chan
  end
  return nil, "RPC_FAILED"
end

--- Execute Lua inside the connected instance. Raises on RPC failure, so
--- callers wrap this in pcall().
function M.exec(chan, code, args)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, args)
end

return M
