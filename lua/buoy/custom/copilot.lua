--- Session-local Copilot plugin. Neovim owns and removes its temporary directory
--- on exit; hiding/reopening a terminal reuses it without changing user settings.
local M = {}
local plugins = {}
local cleanup_registered = false

local function register_cleanup()
  if cleanup_registered then
    return
  end
  cleanup_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    desc = "buoy: remove temporary Copilot plugins",
    callback = function()
      for _, directory in pairs(plugins) do
        vim.fn.delete(directory, "rf")
      end
    end,
  })
end

--- 1.0.83 is the verified compatibility floor for command-based prompt
--- transformation. Older clients may silently ignore unknown hook events.
function M.resolve(opts, callback)
  local function finish(result)
    local major, minor, patch = (result.stdout or ""):match("(%d+)%.(%d+)%.(%d+)")
    local supported = result.code == 0
      and major
      and vim.version.ge({ tonumber(major), tonumber(minor), tonumber(patch) }, { 1, 0, 83 })
    if not supported then
      vim.notify(
        "buoy: GitHub Copilot CLI 1.0.83+ is required for live editor integration; "
          .. "could not verify a compatible version. Launching the terminal only",
        vim.log.levels.WARN
      )
      callback({ opts.cmd })
      return
    end
    local ok, argv, env = pcall(M.argv, opts)
    if not ok then
      vim.notify(tostring(argv) .. "; launching Copilot's terminal only", vim.log.levels.WARN)
      callback({ opts.cmd })
      return
    end
    callback(argv, env)
  end
  local ok = pcall(
    vim.system,
    { opts.cmd, "--version" },
    { text = true, timeout = 2000 },
    vim.schedule_wrap(finish)
  )
  if not ok then
    finish({ code = -1 })
  end
end

function M.argv(opts)
  local integration = require("buoy.instructions").integration(opts.context)
  local guidance = integration.guidance
  if not plugins[guidance] then
    local function hook(mode, matcher, args)
      local argv = require("buoy.instructions").bridge_argv(mode)
      vim.list_extend(argv, args or {})
      return {
        type = "command",
        exec = table.remove(argv, 1),
        args = argv,
        timeoutSec = 10,
        matcher = matcher,
      }
    end

    local hooks = vim.empty_dict()
    if integration.context_hook then
      hooks.userPromptTransformed = { hook("hook-custom", nil, { "copilot_hook.lua" }) }
      hooks.postToolUse = { hook("hook-checktime", "create|edit|str_replace_editor|apply_patch") }
    end

    local directory = vim.fn.tempname()
    assert(
      not directory:find(",", 1, true),
      "buoy: Copilot needs a temporary directory without commas"
    )
    local ok, err = pcall(function()
      assert(vim.fn.mkdir(directory, "p", 448) == 1, "could not create plugin directory") -- 0700
      assert(
        vim.fn.writefile(
          vim.split(guidance, "\n", { plain = true }),
          directory .. "/buoy.instructions.md"
        ) == 0,
        "could not write Copilot instructions"
      )
      assert(
        vim.fn.writefile(
          { vim.json.encode({ name = "buoy-neovim", hooks = "hooks.json" }) },
          directory .. "/plugin.json"
        ) == 0,
        "could not write plugin.json"
      )
      assert(
        vim.fn.writefile(
          { vim.json.encode({ version = 1, hooks = hooks }) },
          directory .. "/hooks.json"
        ) == 0,
        "could not write hooks.json"
      )
    end)
    if not ok then
      vim.fn.delete(directory, "rf")
      error("buoy: could not prepare Copilot hooks: " .. tostring(err))
    end
    plugins[guidance] = directory
    register_cleanup()
  end
  local directory = plugins[guidance]
  local existing = vim.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS
  local directories = existing and existing ~= "" and (existing .. "," .. directory) or directory
  return { opts.cmd, "--plugin-dir", directory }, {
    COPILOT_CUSTOM_INSTRUCTIONS_DIRS = directories,
  }
end

return M
