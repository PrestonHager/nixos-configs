{ config, pkgs, ... }:

{
  imports = [
    # Containers submodule
    ../containers
    # nginx module, further customization available in nginx folder
    #../nginx
    ../caddy
    # Virt-manager
    # see https://nixos.wiki/wiki/Virt-manager for more
    ../virt-manager.nix
    # Wireguard server
    ../wireguard.nix
  ];

  # Enable SSH with keys only
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      # Only enable if absolutely needed
      # PermitRootLogin = true;
    };
  };
}
