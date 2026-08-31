--- Unified one-shot bridge CLI, run by the agent as:
---   <nvim> --headless -u NONE -i NONE -l buoy.lua <mode> [--flag value]
---
--- On-demand operation modes return exactly one JSON object and a meaningful
--- exit status. Internal hook modes deliberately use different contracts:
--- hook-context prints fresh editor context when available, while
--- hook-checktime is output-free; both suppress failures and always exit 0.
--- None of the modes read stdin.

local script_dir = arg[0]:match("^(.*)[/\\]") or "."
local rpc_ok, rpc = pcall(dofile, script_dir .. "/nvim_rpc.lua")
rpc_ok = rpc_ok and type(rpc) == "table"

-- Exit statuses: 0 success, 2 invalid operation/arguments, 3 missing socket
-- or RPC failure, 4 editor rejection, encoding failure, or output limit,
-- 70 unexpected internal failure.
local EXIT_FOR_CODE = {
  INVALID_OPERATION = 2,
  INVALID_ARGUMENT = 2,
  NVIM_UNAVAILABLE = 3,
  RPC_FAILED = 3,
  NO_FILE_IN_CONTEXT = 4,
  BUFFER_NOT_OPEN = 4,
  CAPABILITY_DISABLED = 4,
  FILE_NOT_FOUND = 4,
  NO_EDIT_WINDOW = 4,
  EDITOR_OPERATION_FAILED = 4,
  OUTPUT_LIMIT = 4,
  ENCODING_ERROR = 4,
  INTERNAL = 70,
}

local function close(chan)
  if chan then
    pcall(vim.fn.chanclose, chan)
  end
end

local function run_context_hook()
  pcall(function()
    if not rpc_ok then
      return
    end
    local chan = rpc.connect()
    if not chan then
      return
    end

    local ok, context = pcall(rpc.exec, chan, "return require('buoy.tools').editor_context()", {})
    close(chan)
    if not ok or type(context) ~= "table" then
      return
    end

    local encode_ok, encoded = pcall(vim.json.encode, context)
    if not encode_ok then
      return
    end

    io.write("Current Neovim editor context (auto-refreshed for every prompt):\n")
    io.write(encoded .. "\n")
    io.flush()
  end)
  os.exit(0)
end

local function run_checktime_hook()
  pcall(function()
    if not rpc_ok then
      return
    end
    local chan = rpc.connect()
    if not chan then
      return
    end

    -- A non-interactive :checktime only refreshes buffers displayed in a
    -- window, so check each loaded buffer explicitly to include hidden files.
    local code = [[
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          pcall(vim.cmd, "checktime " .. buf)
        end
      end
    ]]
    pcall(rpc.exec, chan, code, {})
    close(chan)
  end)
  os.exit(0)
end

local mode = arg[1]
if mode == "hook-context" then
  run_context_hook()
elseif mode == "hook-checktime" then
  run_checktime_hook()
end

local function emit(encoded, status)
  io.write(encoded .. "\n")
  io.flush()
  os.exit(status)
end

local function die(code, message, operation)
  local ok, encoded = pcall(vim.json.encode, {
    kind = "error",
    code = code,
    message = message,
    operation = operation or vim.NIL,
  })
  if not ok then
    encoded = '{"kind":"error","code":"INTERNAL","message":"Internal failure.","operation":null}'
    code = "INTERNAL"
  end
  emit(encoded, EXIT_FOR_CODE[code] or 70)
end

local operation = mode
if not operation then
  die("INVALID_OPERATION", "Unknown or missing operation.")
end

local params = {}
local i = 2
while arg[i] do
  local name = arg[i]:match("^%-%-(.+)$")
  if not name then
    die("INVALID_ARGUMENT", "Expected --flag value.", operation)
  end
  local value = arg[i + 1]
  if value == nil then
    die("INVALID_ARGUMENT", "Missing value for flag: --" .. name .. ".", operation)
  end
  local key = name:gsub("%-", "_")
  params[key] = value:match("^%d+$") and tonumber(value) or value
  i = i + 2
end

if not rpc_ok then
  die("INTERNAL", "RPC transport could not be loaded.", operation)
end

local chan, connect_error = rpc.connect()
if not chan then
  if connect_error == "RPC_FAILED" then
    die("RPC_FAILED", "Could not connect to the Neovim session.", operation)
  end
  die("NVIM_UNAVAILABLE", "No running Neovim session socket.", operation)
end

local ok, result =
  pcall(rpc.exec, chan, "return require('buoy.tools').dispatch(...)", { operation, params })
close(chan)
if not ok then
  die("RPC_FAILED", "RPC to the Neovim session failed.", operation)
end
if type(result) ~= "table" then
  die("INTERNAL", "Editor returned an invalid result.", operation)
end
if result.kind == "error" then
  die(result.code or "INTERNAL", result.message or "Internal failure.", operation)
end

-- The result size limit is enforced authoritatively in buoy.tools (which trims
-- to fit or returns OUTPUT_LIMIT); the bridge cannot re-trim, only reject.
local encode_ok, encoded = pcall(vim.json.encode, result)
if not encode_ok then
  die("ENCODING_ERROR", "Result could not be encoded as JSON.", operation)
end
emit(encoded, 0)
