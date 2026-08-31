--- One-shot startup opening and its layout-aware reminder.

local M = {}

local scheduled = false
local reminder_pending = false

--- Build the reminder shown after a successful automatic open.
function M.message(keymaps, layout)
  local actions
  if layout == "float" then
    actions = {
      primary = "hide agent",
      secondary = "switch between agent and code",
    }
  else
    actions = {
      primary = "switch between agent and code",
      secondary = "hide agent",
    }
  end

  local shortcuts = {}
  for _, role in ipairs({ "primary", "secondary" }) do
    local key = keymaps[role]
    if key then
      shortcuts[#shortcuts + 1] = ("%s: %s"):format(key, actions[role])
    end
  end

  if #shortcuts == 0 then
    return "Buoy enabled"
  end
  return "Buoy enabled · " .. table.concat(shortcuts, " · ")
end

local function echo_reminder(message)
  reminder_pending = true
  vim.api.nvim_echo({ { message } }, false, {})
end

--- Clear the startup reminder on the first configured Buoy key action.
function M.dismiss_reminder()
  if not reminder_pending then
    return
  end

  reminder_pending = false
  vim.api.nvim_echo({ { "" } }, false, {})
end

local function restore_window(tab, win)
  if vim.api.nvim_get_current_tabpage() ~= tab or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_tabpage(win) == tab then
    vim.api.nvim_set_current_win(win)
  end
end

local function open_once()
  local plugin = require("buoy")
  local terminal = require("buoy.terminal")
  if terminal.is_visible() then
    return
  end

  local tab = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  local ok, err = pcall(terminal.open)
  restore_window(tab, win)
  if not ok then
    error(err, 0)
  end

  -- A missing executable and any other handled launch failure leave no visible
  -- window; those paths keep their existing notification and get no success
  -- reminder.
  if not terminal.is_visible() then
    return
  end
  if plugin.config.startup.message then
    echo_reminder(M.message(plugin.config.keymaps, terminal.current_layout()))
  end
end

--- Arrange exactly one automatic-open callback for this Neovim instance.
function M.schedule()
  if scheduled then
    return
  end
  scheduled = true

  local function queue_open()
    vim.schedule(open_once)
  end

  if vim.v.vim_did_enter == 1 then
    queue_open()
    return
  end

  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("BuoyStartup", { clear = true }),
    once = true,
    callback = queue_open,
    desc = "buoy: open the agent after startup",
  })
end

return M
