{ config, pkgs, lib ? pkgs.lib, ... }:

{
  programs.neovim = {
    enable = true;
    withNodeJs = true;
    viAlias = true;
    vimAlias = true;
    plugins = with pkgs.vimPlugins; [
      nvim-cmp
      obsidian-nvim
      telescope-nvim
      vim-tmux-navigator
      copilot-vim
      nvim-treesitter.withAllGrammars
    ];
    extraConfig = ''
      set number
      set tabstop=2 softtabstop=2 shiftwidth=2
      set expandtab
      set textwidth=80
      set clipboard^=unnamed,unnamedplus

      let g:tmux_navigator_no_mappings = 1

      nnoremap <silent> <M-h> :TmuxNavigateLeft<cr>
      nnoremap <silent> <M-j> :TmuxNavigateDown<cr>
      nnoremap <silent> <M-k> :TmuxNavigateUp<cr>
      nnoremap <silent> <M-l> :TmuxNavigateRight<cr>
      nnoremap <silent> <M-\> :TmuxNavigatePrevious<cr>
    '';
    extraLuaConfig = ''
      -- Enable treesitter highlighting
      require('nvim-treesitter.configs').setup({
        highlight = {
          enable = true,
        },
        indent = {
          enable = true,
        },
      })
    '';
  };
}

