{ config, pkgs, ... }:

{
  # Add any imports here for things that need their own config file
#  imports = [
#  ];

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
