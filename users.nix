{ lib, config, pkgs, ... }:

{
  options = {
    users = {
      main = {
        enable = lib.mkEnableOption "Enable the main user";
        username = lib.mkOption {
          default = "user";
          description = ''
            username
          '';
        };
        name = lib.mkOption {
          default = "User";
          description = ''
            First (Last) name of the user
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
  };
}
