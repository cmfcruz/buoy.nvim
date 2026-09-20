local M = {}
local warned_windows = false

function M.resolve(agent, cmd, cwd, callback)
  if vim.fn.has("win32") == 1 then
    if not warned_windows then
      warned_windows = true
      vim.notify(
        "buoy: live editor context and operations are unavailable on Windows; launching the terminal only",
        vim.log.levels.WARN
      )
    end
    callback({ cmd })
    return
  end

  local preset = require("buoy.agents").get(agent)
  assert(preset, "buoy: missing adapter for configured agent " .. tostring(agent))
  require(preset.module).resolve({
    cmd = cmd,
    cwd = cwd,
    context = require("buoy").config.context,
  }, callback)
end

return M
