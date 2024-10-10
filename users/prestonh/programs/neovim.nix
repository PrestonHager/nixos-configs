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
	    nvim-treesitter
	];
	extraConfig = ''
	    set number
	    set tabstop=2 softtabstop=2 shiftwidth=2
	    set expandtab
	    set textwidth=80
	    set clipboard=xclip
	'';
    };

    # Allow unfree packages for certain plugins
#    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
#    ];
}

