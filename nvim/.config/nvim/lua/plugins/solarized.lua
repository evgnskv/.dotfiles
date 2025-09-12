return {
  "craftzdog/solarized-osaka.nvim",
  lazy = false,
  priority = 1000,
  opts = {},

  config = function()
    vim.o.termguicolors = true
    vim.cmd.colorscheme("solarized-osaka")
  end,
}
