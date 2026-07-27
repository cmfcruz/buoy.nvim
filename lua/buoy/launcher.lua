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

  local instructions = require("buoy.instructions")
  local context = require("buoy").config.context
  -- config.context already carries exactly the keys neovim_instructions reads,
  -- so pass it straight through instead of rebuilding the table.
  local neovim_instructions = instructions.neovim_instructions(context)
  -- expose_editor_context off ⇒ no per-prompt snapshot; a nil hook_command makes
  -- the argv builders omit the UserPromptSubmit hook entirely.
  local hook_command = context.expose_editor_context and instructions.hook_command() or nil
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
