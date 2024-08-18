{ config, pkgs, lib ? pkgs.lib, ... }:

let
  cfg = config.users.users;
in {
  options = {
    users = {
      main = {
        enable = lib.mkEnableOption "Enable the main user";
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
        home-manager = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Import a home-manager configuration
          '';
        };
      };
    };
  };

  config = lib.mkIf config.users.main.enable {
    users.users.${config.users.main.username} = {
      isNormalUser = true;
      description = "${config.users.main.name}";
      extraGroups = [ "networkmanager" "wheel" ];
      packages = with pkgs; [];
      shell = pkgs.zsh;
    };
#      home-manager = lib.mkIf (${config.users.main.home-manager} != null) {
#        extraSpecialArgs = { inherit inputs; };
#        users = {
#          "${config.users.main.username}" = ${config.users.main.home-manager};
#        };
  };
}
