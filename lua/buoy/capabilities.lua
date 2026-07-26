--- Single source of truth for buoy's gated, agent-facing capabilities.
--- Config, instructions, and tools all read defaults and keys from here so no
--- module re-declares them. Bridge scripts never use this (separate process).
local M = {}

-- Ordered for deterministic config defaulting and iteration. Each key mirrors a
-- `context.*` switch in the public config:
--   expose_buffers        allow get_buffer_range (agent reads live buffer contents)
--   expose_diagnostics    allow get_diagnostics (agent reads buffer diagnostics)
--   expose_editor_context attach the per-prompt editor snapshot + selection handoff
M.list = {
  { key = "expose_buffers", default = true },
  { key = "expose_diagnostics", default = true },
  { key = "expose_editor_context", default = true },
}

M.defaults = {}
for _, c in ipairs(M.list) do
  M.defaults[c.key] = c.default
end

--- Fill a possibly-partial context table with each capability's default,
--- returning concrete booleans. Handles nil (no-arg) input.
function M.resolve(context)
  context = context or {}
  local out = {}
  for _, c in ipairs(M.list) do
    local v = context[c.key]
    out[c.key] = (v == nil) and c.default or v
  end
  return out
end

return M
