{ config, pkgs, ... }:

{
  imports = [
    ../auth
    ../monitoring
    # Containers submodule
    ../containers
    ../caddy
    # Virt-manager
    # see https://nixos.wiki/wiki/Virt-manager for more
    ../virt-manager.nix
    # Wireguard server
    ../wireguard.nix
  ];

  services.zitadel-sso.enable = true;

  # Enable SSH with keys only
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Only enable if absolutely needed
      # PermitRootLogin = true;
    };
  };
}
