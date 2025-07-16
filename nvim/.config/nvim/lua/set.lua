vim.cmd("set expandtab")
vim.cmd("set tabstop=2")
vim.cmd("set shiftwidth=2")
vim.cmd("set softtabstop=2")

vim.cmd("set autoindent")
vim.cmd("set smartindent")

vim.cmd("set number")

vim.cmd("set clipboard=unnamedplus")

vim.opt.swapfile = false
vim.wo.number = true

vim.g.mapleader = " "
vim.keymap.set("n", "<c-k>", ":wincmd k<CR>")
vim.keymap.set("n", "<c-j>", ":wincmd j<CR>")
vim.keymap.set("n", "<c-h>", ":wincmd h<CR>")
vim.keymap.set("n", "<c-l>", ":wincmd l<CR>")
