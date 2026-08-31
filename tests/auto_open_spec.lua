local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:prepend(root)
for name in pairs(package.loaded) do
  if name == "buoy" or name:find("^buoy%.") then
    package.loaded[name] = nil
  end
end

local function fail(message)
  error(message, 2)
end

local function eq(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    fail(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(value, label)
  if not value then
    fail(label)
  end
end

local ok, err = xpcall(function()
  local original_schedule = vim.schedule
  local original_echo = vim.api.nvim_echo
  local original_serverstart = vim.fn.serverstart
  local original_executable = vim.fn.executable
  local original_agent = vim.env.BUOY_AGENT
  local queue, echoes = {}, {}

  vim.schedule = function(callback)
    queue[#queue + 1] = callback
  end
  vim.api.nvim_echo = function(chunks)
    echoes[#echoes + 1] = chunks[1][1]
  end
  vim.fn.serverstart = function()
    return "/tmp/buoy-auto-open-spec.sock"
  end
  vim.fn.executable = function()
    return 1
  end
  vim.env.BUOY_AGENT = "codex"

  package.loaded["buoy.context"] = {
    setup = function() end,
  }

  local visible, layout, agent_win, opens, primary_calls, secondary_calls
  local function install_terminal(target_layout)
    visible, layout, agent_win, opens = false, target_layout, nil, 0
    primary_calls, secondary_calls = 0, 0
    package.loaded["buoy.terminal"] = {
      is_visible = function()
        return visible
      end,
      current_layout = function()
        return layout
      end,
      open = function()
        opens = opens + 1
        if target_layout == "vsplit" then
          vim.cmd("vsplit")
          agent_win = vim.api.nvim_get_current_win()
        else
          local buf = vim.api.nvim_create_buf(false, true)
          agent_win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            row = 1,
            col = 1,
            width = 40,
            height = 5,
            style = "minimal",
          })
        end
        visible = true
      end,
      on_primary = function()
        primary_calls = primary_calls + 1
      end,
      on_secondary = function()
        secondary_calls = secondary_calls + 1
      end,
      on_resize = function() end,
      relayout = function() end,
    }
  end

  local function reset(target_layout)
    queue, echoes = {}, {}
    package.loaded["buoy"] = nil
    package.loaded["buoy.startup"] = nil
    install_terminal(target_layout)
  end

  local function run_queue()
    while #queue > 0 do
      table.remove(queue, 1)()
    end
  end

  local original_win = vim.api.nvim_get_current_win()
  reset("vsplit")
  local buoy = require("buoy")
  buoy.setup({ window = { style = "vsplit" } })
  eq(true, buoy.config.startup.open, "startup.open defaults on")
  eq(true, buoy.config.startup.message, "startup.message defaults on")
  run_queue()
  eq(1, opens, "explicit setup automatically opens once")
  eq(original_win, vim.api.nvim_get_current_win(), "vsplit startup restores editor focus")
  eq(
    "Buoy enabled · <F2>: switch between agent and code · <S-F2>: hide agent",
    echoes[1],
    "vsplit reminder describes the configured layout-aware actions"
  )
  vim.api.nvim_feedkeys(vim.keycode("<F2>"), "mx", false)
  eq("", echoes[2], "the first primary action dismisses the startup reminder")
  eq(1, primary_calls, "dismissing the reminder still runs the primary action")
  vim.api.nvim_feedkeys(vim.keycode("<F2>"), "mx", false)
  eq(2, #echoes, "later primary actions do not clear future messages")
  eq(2, primary_calls, "later primary actions still run normally")
  vim.api.nvim_win_close(agent_win, true)

  original_win = vim.api.nvim_get_current_win()
  reset("float")
  buoy = require("buoy")
  buoy.setup({
    window = { style = "float" },
    keymaps = { primary = "<C-b>", secondary = "<leader>b" },
  })
  run_queue()
  eq(1, opens, "float startup opens once")
  eq(original_win, vim.api.nvim_get_current_win(), "float startup restores editor focus")
  eq(
    "Buoy enabled · <C-b>: hide agent · <leader>b: switch between agent and code",
    echoes[1],
    "float reminder preserves custom key notation"
  )
  vim.api.nvim_feedkeys(vim.keycode("<leader>b"), "mx", false)
  eq("", echoes[2], "the first secondary action dismisses the startup reminder")
  eq(1, secondary_calls, "dismissing the reminder still runs the secondary action")
  vim.api.nvim_win_close(agent_win, true)

  reset("float")
  buoy = require("buoy")
  buoy.setup({ startup = { open = false } })
  run_queue()
  eq(0, opens, "startup.open=false keeps startup manual")

  reset("float")
  buoy = require("buoy")
  buoy.setup({ startup = { message = false } })
  run_queue()
  eq(1, opens, "startup.message=false still opens")
  eq(0, #echoes, "startup.message=false suppresses the reminder")
  vim.api.nvim_win_close(agent_win, true)

  reset("vsplit")
  visible = true
  buoy = require("buoy")
  buoy.setup()
  run_queue()
  eq(0, opens, "an already-visible agent is not reopened")
  eq(0, #echoes, "an already-visible agent is not announced")

  local startup = require("buoy.startup")
  eq(
    "Buoy enabled · <F2>: switch between agent and code",
    startup.message({ primary = "<F2>", secondary = false }, "vsplit"),
    "a disabled secondary key is omitted"
  )
  eq(
    "Buoy enabled",
    startup.message({ primary = false, secondary = false }, "float"),
    "no shortcut is invented when both mappings are disabled"
  )

  -- Zero configuration follows the same scheduler: plugin loading queues
  -- setup, and setup queues the one automatic open.
  reset("vsplit")
  vim.g.loaded_buoy = nil
  pcall(vim.api.nvim_del_user_command, "Buoy")
  pcall(vim.api.nvim_del_user_command, "BuoyToggle")
  dofile(root .. "/plugin/buoy.lua")
  run_queue()
  eq(1, opens, "zero-configuration startup opens once")
  truthy(require("buoy")._did_setup, "zero-configuration startup applies setup")
  vim.api.nvim_win_close(agent_win, true)

  vim.schedule = original_schedule
  vim.api.nvim_echo = original_echo
  vim.fn.serverstart = original_serverstart
  vim.fn.executable = original_executable
  vim.env.BUOY_AGENT = original_agent
end, debug.traceback)

if not ok then
  error(err)
end

print("auto_open_spec: ok")
