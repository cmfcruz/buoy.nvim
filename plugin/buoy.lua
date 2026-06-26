if vim.g.loaded_buoy then
  return
end
vim.g.loaded_buoy = true

vim.api.nvim_create_user_command("Buoy", function()
  require("buoy.terminal").toggle()
end, { desc = "Toggle the buoy agent window" })

vim.api.nvim_create_user_command("BuoyFocus", function()
  require("buoy.terminal").open()
end, { desc = "Open/focus the buoy agent window" })
