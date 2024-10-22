{ config, pkgs, ... }:

{
  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # Recursively add all files from the config directory
    ".config/" = {
      source = ./config;
      recursive = true;
    };
#    ".config/user-dirs.dirs".source = ./config/user-dirs.dirs;

    # zshrc file
    ".zshrc".source = ./zshrc;
  };

  # Create a systemd service that runs once whenever
  # sysinit-reactivation.target is activated to update neovim plugins
#  systemd.user.services.update-neovim-plugins = {
#    Unit = {
#      Description = "Update neovim plugins";
#      After = [ "sysinit-reactivation.target" ];
#    };
#    Install = {
#      WantedBy = [ "default.target" "sysinit-reactivation.target" ];
#    };
#    Service = {
#      Type = "oneshot";
#      ExecStart = "${pkgs.neovim}/bin/nvim --headless '+Lazy! sync' +qa";
#    };
#  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. If you don't want to manage your shell through Home
  # Manager then you have to manually source 'hm-session-vars.sh' located at
  # either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/prestonh/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
    SUDO_EDITOR = "nvim";
#    TERMINAL = "kitty";
  };
}
