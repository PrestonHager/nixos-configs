-- init.lua

-- commands migrated from init.vim
vim.cmd ([[
set number
set tabstop=2 softtabstop=2 shiftwidth=2
set expandtab
set textwidth=80
set clipboard=unnamedplus
]])

-- activate the lazy plugin loader
require("config.lazy") 
