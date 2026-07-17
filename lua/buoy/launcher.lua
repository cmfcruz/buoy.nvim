local M = {}
local warned_windows = false

function M.resolve(agent, cmd, cwd, callback)
  if vim.fn.has("win32") == 1 then
    if not warned_windows then
      warned_windows = true
      vim.notify(
        "buoy: live editor context and operations are unavailable on Windows in v2; launching the terminal only",
        vim.log.levels.WARN
      )
    end
    callback({ cmd })
    return
  end

  local instructions = require("buoy.instructions")
  local neovim_instructions = instructions.neovim_instructions()
  local hook_command = instructions.hook_command()
  if agent == "claude" then
    callback(instructions.claude_argv(cmd, neovim_instructions, hook_command))
    return
  end

  require("buoy.codex").resolve(cmd, cwd, function(err, existing)
    if err then
      vim.notify(
        "buoy: "
          .. err
          .. "; on-demand live editor operations are unavailable for this Codex session",
        vim.log.levels.WARN
      )
      callback(instructions.codex_argv(cmd, nil, hook_command))
      return
    end
    local developer_instructions = instructions.append_instructions(existing, neovim_instructions)
    callback(instructions.codex_argv(cmd, developer_instructions, hook_command))
  end)
end

return M
