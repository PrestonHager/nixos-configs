{ config, pkgs, ... }:

{
  imports = [
    ./desktop.nix
    ./programs/steam.nix
  ];

  environment.systemPackages = with pkgs; [
    # MSI-mission control center
    mcontrolcenter
  ];

  # Uncomment if needed
  #services.openssh = {
  #  enable = true;
  #  settings = {
  #    PasswordAuthentication = true;
  #    KbdInteractiveAuthentication = false;
  #    # Only enable if absolutely needed
  #    # PermitRootLogin = true;
  #  };
  #};
}
