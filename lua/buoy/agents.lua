--- Registry for supported agent adapters and their zero-configuration order.
local M = {}

M.order = { "claude", "codex", "pi", "copilot" }

local presets = {
  claude = { cmd = "claude", title = " Claude Code ", module = "buoy.custom.claude" },
  codex = { cmd = "codex", title = " Codex ", module = "buoy.custom.codex" },
  pi = { cmd = "pi", title = " Pi ", module = "buoy.custom.pi" },
  copilot = { cmd = "copilot", title = " GitHub Copilot ", module = "buoy.custom.copilot" },
}

function M.get(name)
  return presets[name]
end

function M.expected()
  local names = { "'auto'" }
  for _, name in ipairs(M.order) do
    names[#names + 1] = "'" .. name .. "'"
  end
  return table.concat(names, ", ")
end

--- Resolve `auto` by the documented preference order. If nothing is installed,
--- return the first preset so terminal startup can report its missing command.
function M.resolve(name)
  if name ~= "auto" then
    return name
  end
  for _, candidate in ipairs(M.order) do
    if vim.fn.executable(presets[candidate].cmd) == 1 then
      return candidate
    end
  end
  return M.order[1]
end

return M
