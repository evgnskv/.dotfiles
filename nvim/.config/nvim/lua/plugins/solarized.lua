return { 
  "maxmx03/solarized.nvim", 
  name = "solarized", 
  priority = 1000, 
  lazy = false,

  config = function()
    vim.o.termguicolors = true
    vim.cmd.colorscheme 'solarized'
  end
}