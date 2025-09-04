return {
  "nvimtools/none-ls.nvim",

  config = function()
    local null_ls = require("null-ls")
    local mason_registry = require("mason-registry")

    vim.keymap.set("n", "<leader>gf", vim.lsp.buf.format, {})
  end,
}
