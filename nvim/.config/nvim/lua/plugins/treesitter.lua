return {
  "nvim-treesitter/nvim-treesitter",
  branch = 'master',
  lazy = false, 
  build = ":TSUpdate",

  config = function()
    local config = require('nvim-treesitter.configs')
    config.setup({
      ensure_installed = { 
        "bash",
        "lua",
        "python",
        "helm",
        "sql",
        "markdown",
        "markdown_inline"
        },
      highlight = {
        enable = true,
        additional_vim_regex_highlighting = false,
      },
      indent = { enable = true },
    })
  end
}
