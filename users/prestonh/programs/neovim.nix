{ config, pkgs, inputs, ... }:

let
  treesitterWithGrammars = (pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
    inputs.tree-sitter-parsers.packages.x86_64-linux.tree-sitter-move
    inputs.tree-sitter-parsers.packages.x86_64-linux.tree-sitter-nu
  ]));
  treesitter-parsers = pkgs.symlinkJoin {
    name = "treesitter-parsers";
    paths = treesitterWithGrammars.dependencies;
  };
  nvim-plugins = with pkgs.vimPlugins; [
    nvim-cmp
    obsidian-nvim
    telescope-nvim
    vim-tmux-navigator
    copilot-vim
    neo-tree-nvim
    treesitterWithGrammars
    nvim-treesitter.withAllGrammars
  ];
in
{
  programs.neovim = {
    enable = true;
    withRuby = true;
    withPython3 = true;
    withNodeJs = true;
    viAlias = true;
    vimAlias = true;
    plugins = nvim-plugins;
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
    initLua = ''
      -- Enable treesitter highlighting
      package.path = package.path ..
        ";${pkgs.vimPlugins.nvim-treesitter}/lua/?.lua"
      require('nvim-treesitter.configs').setup({
        highlight = {
          enable = true,
        },
        indent = {
          enable = true,
        },
      })

      -- Set tab width for java file type
      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'java',
        callback = function()
          vim.opt_local.tabstop = 4
          vim.opt_local.shiftwidth = 4
          vim.opt_local.expandtab = true
        end,
      })

      vim.opt.runtimepath:append("${treesitter-parsers}")
    '';
  };

  home.file."./.local/share/nvim/nix/nvim-treesitter/" = {
  recursive = true;
    source = treesitterWithGrammars;
  };

  home.packages = with pkgs; [
    xsel
  ];
}

