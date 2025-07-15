return {
    {
        "mason-org/mason.nvim",
        config = function()
            require("mason").setup()
        end,
    },
    {
        "mason-org/mason-lspconfig.nvim",
        opts = {},
        dependencies = {
            { "mason-org/mason.nvim", opts = {} },
            "neovim/nvim-lspconfig",
        },

        config = function()
            require("mason-lspconfig").setup({
                ensure_installed = {
                    "bashls",   -- LSP https://github.com/bash-lsp/bash-language-server
                    "lua_ls",   -- LSP https://github.com/LuaLS/lua-language-server
                    "pylsp",    -- LSP https://github.com/python-lsp/python-lsp-server
                    "ruby_lsp", -- LSP https://github.com/Shopify/ruby-lsp
                    "helm_ls",  -- LSP https://github.com/mrjosh/helm-ls
                    "sqls",     -- LSP https://github.com/sqls-server/sqls
                },

                automatic_enable = true,
            })
        end,
    },
}
