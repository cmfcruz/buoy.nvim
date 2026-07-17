if vim.g.loaded_buoy then
  return
end
vim.g.loaded_buoy = true

local function capture_command_selection(opts)
  if opts.range > 0 then
    require("buoy.context").capture_command_selection(opts.line1, opts.line2)
  end
end

vim.api.nvim_create_user_command("Buoy", function(opts)
  require("buoy").ensure_setup()
  capture_command_selection(opts)
  require("buoy.terminal").open()
end, { desc = "Open/focus the buoy agent window", range = true })

vim.api.nvim_create_user_command("BuoyToggle", function(opts)
  require("buoy").ensure_setup()
  capture_command_selection(opts)
  require("buoy.terminal").toggle()
end, { desc = "Toggle the buoy agent window", range = true })

-- Zero-config path: if the user never calls require("buoy").setup(), apply
-- defaults automatically so a bare `git clone` into pack/ just works (socket
-- published, live context ready, <F2> mapped, agent auto-detected). Deferred so
-- an explicit setup() in the user's config runs first and wins.
vim.schedule(function()
  require("buoy").ensure_setup()
end)
