return {
  {
    "mason-org/mason-lspconfig.nvim",
    opts = {},
    dependencies = {
      {
        "mason-org/mason.nvim", opts = {}
      },
        "neovim/nvim-lspconfig",
    },
    config = function()
      require("mason-lspconfig").setup {
        ensure_installed = {
          "bashls",     -- https://github.com/bash-lsp/bash-language-server
          "lua_ls",     -- https://github.com/LuaLS/lua-language-server
          "pylsp",      -- https://github.com/python-lsp/python-lsp-server
          "ruby_lsp",   -- https://github.com/Shopify/ruby-lsp
          "helm_ls",    -- https://github.com/mrjosh/helm-ls
          "sqls"        -- https://github.com/sqls-server/sqls
        },
        automatic_enable = true,
      }
    end
  }
}
