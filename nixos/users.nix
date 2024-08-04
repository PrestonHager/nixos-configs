{ lib, config, pkgs, ... }:

{
  options = {
    users = {
      main = {
        enable = lib.mkEnableOption "Enable the main user";
        username = lib.mkOption {
          description = ''
            username
          '';
        };
        name = lib.mkOption {
          description = ''
            First (Last) name of the user
          '';
        };
        home-manager = lib.mkOption {
          default = null;
          description = ''
            Import a home-manager configuration
          '';
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
    home-manager = lib.mkIf (${config.users.main.home-manager} != null) {
      extraSpecialArgs = { inherit inputs; };
      users = {
        "${config.users.main.username}" = ${config.users.main.home-manager};
      };
    };
  };
}
