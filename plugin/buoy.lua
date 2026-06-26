if vim.g.loaded_buoy then
  return
end
vim.g.loaded_buoy = true

vim.api.nvim_create_user_command("Buoy", function()
  require("buoy.terminal").toggle()
end, { desc = "Toggle the buoy agent window", range = true })

vim.api.nvim_create_user_command("BuoyFocus", function()
  require("buoy.terminal").open()
end, { desc = "Open/focus the buoy agent window", range = true })

-- Zero-config path: if the user never calls require("buoy").setup(), apply
-- defaults automatically so a bare `git clone` into pack/ just works (socket
-- published, MCP context live, <F2> mapped, agent auto-detected). Deferred so
-- an explicit setup() in the user's config runs first and wins.
vim.schedule(function()
  local buoy = require("buoy")
  if not buoy._did_setup then
    buoy.setup()
  end
end)
