return {
    "folke/tokyonight.nvim",
    name = "tokyonight",
    priority = 1000,
    lazy = false,

    config = function()
        vim.o.termguicolors = true
        vim.cmd.colorscheme("tokyonight")
    end,
}
