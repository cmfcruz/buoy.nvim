--- One-shot agent CLI adapter, run by the agent's shell tool as:
---   <nvim> --headless -u NONE -i NONE -l agent_cli.lua <operation> [--flag value]
---
--- Connects to the user's running Neovim over the session socket (see
--- nvim_rpc.lua), performs one operation via require("buoy.tools") inside
--- that instance, and writes exactly one JSON object followed by a newline
--- on stdout. Handled failures are JSON too; stderr is reserved for failures
--- so early that no JSON object can be produced.

local script_dir = arg[0]:match("^(.*)[/\\]") or "."
local rpc = dofile(script_dir .. "/nvim_rpc.lua")

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

local operation = arg[1]
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

local chan, connect_error = rpc.connect()
if not chan then
  if connect_error == "RPC_FAILED" then
    die("RPC_FAILED", "Could not connect to the Neovim session.", operation)
  end
  die("NVIM_UNAVAILABLE", "No running Neovim session socket.", operation)
end

local ok, result =
  pcall(rpc.exec, chan, "return require('buoy.tools').dispatch(...)", { operation, params })
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
-- to fit or returns OUTPUT_LIMIT); the bridge cannot re-trim, only reject, so it
-- trusts that enforcement and does not re-check the encoded byte length here.
local encode_ok, encoded = pcall(vim.json.encode, result)
if not encode_ok then
  die("ENCODING_ERROR", "Result could not be encoded as JSON.", operation)
end
emit(encoded, 0)
