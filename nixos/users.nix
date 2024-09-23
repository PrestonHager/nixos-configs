{ config, pkgs, inputs, lib ? pkgs.lib, ... }:

let
  cfg = config.users.users;
  userOpts = { ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = true;
        description = "Whether to enable this user. Defaults to true.";
      };
      username = lib.mkOption {
        type = lib.types.str;
        example = "jaydoe";
        description = ''
          username
        '';
      };
      name = lib.mkOption {
        type = lib.types.str;
        example = "Jay Doe";
        description = ''
          First (Last) name of the user
        '';
      };
      home-manager = {
        enable = lib.mkEnableOption "home-manager for this user";
        path = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Import a home-manager configuration
          '';
        };
      };
    };
  };
in {
  options = {
    short-users = 
      lib.mkOption {
        type = lib.types.listOf (lib.types.submodule userOpts);
        description = "Users to create";
      };
  };

  # Create the config if at least one user exists and is enabled in the options
  config = lib.mkIf
    (config.short-users != null && builtins.any (user: user.enable) config.short-users) {
    # Create the users attribute set with each user's configuration
    users.users = builtins.listToAttrs
      (builtins.map (user: {
        name = "${user.username}";
        value = {
          isNormalUser = true;
          description = "${user.name}";
          extraGroups = [ "networkmanager" "wheel" ];
          packages = with pkgs; [];
          shell = pkgs.zsh;
          hashedPasswordFile = 
            lib.mkIf
            (builtins.pathExists (./. + "/../users/${user.username}/passwd"))
            "/../nixos/users/${user.username}/passwd";
        };
      }) (builtins.filter (user: user.enable) config.short-users));
    # Setup home manager if enabled (not null)
    home-manager = lib.mkIf
      (builtins.any (user: user.home-manager != null) config.short-users) {
      extraSpecialArgs = { inherit inputs; };
      users = builtins.listToAttrs
        (builtins.map (user: {
          name = "${user.username}";
          value = if builtins.isNull user.home-manager.path then
            import (./. + "/../users/${user.username}/home.nix") else
            import user.home-manager.path;
        }) (builtins.filter (user: user.home-manager != null &&
          user.home-manager.enable) config.short-users));
    };
  };

}
