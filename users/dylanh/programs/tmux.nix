{config, pkgs, lib ? pkgs.lib, ... }:

#let
#  tmux-super-fingers = pkgs.tmuxPlugins.mkTmuxPlugin
#    {
#      pluginName = "tmux-super-fingers";
#      version = "unstable-2023-01-06";
#      src = pkgs.fetchFromGitHub {
#        owner = "artemave";
#        repo = "tmux_super_fingers";
#        rev = "2771f791a03880b3653c043cff48ee81db66212b";
#        sha256 = "sha256-GnVlV8JRKVx6muVKYvqkCSMds7IBTYp1NFEgQnnuYEc=";
#      };
#    };
#in
{
  programs.tmux = {
    enable = true;
    shell = "${pkgs.zsh}/bin/zsh";
    terminal = "tmux-256color";
    historyLimit = 100000;
    plugins = with pkgs; [
      {
        plugin = tmuxPlugins.catppuccin;
        extraConfig = '' 
          set -g @catppuccin_flavour 'mocha'
          set -g @catppuccin_window_tabs_enabled on

          set -g @catppuccin_window_right_separator "█ "
          set -g @catppuccin_window_number_position "right"
          set -g @catppuccin_window_middle_separator " | "

          set -g @catppuccin_window_default_fill "none"

          set -g @catppuccin_window_current_fill "all"

          set -g @catppuccin_status_modules_right "application session user host date_time"
          set -g @catppuccin_status_left_separator "█"
          set -g @catppuccin_status_right_separator "█"

          set -g @catppuccin_date_time_text "%Y-%m-%d %H:%M:%S"
        '';
      }
#      {
#        plugin = tmux-super-fingers;
#        extraConfig = ''
#          set -g @super-fingers-key f
#        '';
#      }

      tmuxPlugins.better-mouse-mode

      {
        plugin = tmuxPlugins.resurrect;
        extraConfig = ''
          set -g @resurrect-strategy-vim 'session'
          set -g @resurrect-strategy-nvim 'session'
          set -g @resurrect-capture-pane-contents 'on'
        '';
      }
      {
        plugin = tmuxPlugins.continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-boot 'on'
          set -g @continuum-save-interval '10'
        '';
      }
    ];
    extraConfig = ''
      unbind C-b
      set -g prefix C-Space
      bind C-Space send-prefix

      # Set start of numbering at 1 to make for easier keyboard entry
      set -g base-index 1
      setw -g pane-base-index 1
      # Also reorder windows after removing one in between two
      set -g renumber-windows on

      set-option -sa terminal-overrides ",xterm*:Tc"
      set -g mouse on

      # Quick reload for faster development, turn off when not in use
      bind r source-file $HOME/.config/tmux/tmux.conf \; display "Reloaded!"

      # Setup for vim-tmux-navigator
      # See: https://github.com/christoomey/vim-tmux-navigator
      is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
          | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|l?n?vim?x?|fzf)(diff)?$'"
      bind-key -n 'M-h' if-shell "$is_vim" 'send-keys M-h'  'select-pane -L'
      bind-key -n 'M-j' if-shell "$is_vim" 'send-keys M-j'  'select-pane -D'
      bind-key -n 'M-k' if-shell "$is_vim" 'send-keys M-k'  'select-pane -U'
      bind-key -n 'M-l' if-shell "$is_vim" 'send-keys M-l'  'select-pane -R'
      tmux_version='$(tmux -V | sed -En "s/^tmux ([0-9]+(.[0-9]+)?).*/\1/p")'
      if-shell -b '[ "$(echo "$tmux_version < 3.0" | bc)" = 1 ]' \
          "bind-key -n 'M-\\' if-shell \"$is_vim\" 'send-keys M-\\'  'select-pane -l'"
      if-shell -b '[ "$(echo "$tmux_version >= 3.0" | bc)" = 1 ]' \
          "bind-key -n 'M-\\' if-shell \"$is_vim\" 'send-keys M-\\\\'  'select-pane -l'"

      bind-key -T copy-mode-vi 'M-h' select-pane -L
      bind-key -T copy-mode-vi 'M-j' select-pane -D
      bind-key -T copy-mode-vi 'M-k' select-pane -U
      bind-key -T copy-mode-vi 'M-l' select-pane -R
      bind-key -T copy-mode-vi 'M-\' select-pane -l
    '';
  };
}

