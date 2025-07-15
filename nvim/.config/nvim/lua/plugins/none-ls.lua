return {
  "nvimtools/none-ls.nvim",

  config = function()
  local null_ls = require("null-ls")
  local tools = {
    "stylua",     -- FMT https://github.com/JohnnyMorganz/StyLua
    "shfmt",      -- FMT https://github.com/mvdan/sh
    "rubocop",    -- LNT https://github.com/rubocop/rubocop
    "black"       -- FMT https://github.com/psf/black
   }

  local mason_registry = require("mason-registry")
  for _, tool in ipairs(tools) do
    if not mason_registry.is_installed(tool) then
      vim.cmd("MasonInstall " .. tool)
    end
  end

  null_ls.setup({
    sources = {
      null_ls.builtins.formatting.stylua,
      null_ls.builtins.formatting.shfmt,

      null_ls.builtins.diagnostics.rubocop,
      null_ls.builtins.formatting.rubocop,

      null_ls.builtins.formatting.black,

      null_ls.builtins.completion.spell,
    },
  })

  vim.keymap.set('n', '<leader>gf', vim.lsp.buf.format, {})
  end
}

