{ config, inputs, pkgs, ... }:

{
  imports = [
    ../../nixos
    ../../nixos/headless
    # hardware configuration for the Dell Workstations
    ../../hardware/dell-optiplex-7050/hardware-configuration.nix
    # include any users
    ../../users/prestonh
  ];

  # Enable docker for wings backend
  virtualisation.docker = {
    enable = true;
  };

  environment.systemPackages = [
    inputs.pterodactyl-wings.packages.x86_64-linux.wings
  ];

  # Create systemd service for the wings binary
  systemd.tmpfiles.rules = [
    "d /etc/pterodactyl 0775 root root -"
  ];
  systemd.services.wings = {
    enable = true;
    description = "Daemon for the Pterodactyl Wings binary";

    unitConfig = {
      After = [ "docker.service" ];
    };

    serviceConfig = {
      WorkingDirectory = "/etc/pterodactyl";
      ExecStart = "${inputs.pterodactyl-wings.packages.x86_64-linux.wings}/bin/wings";
      PIDFile = "/var/run/wings/daemon.pid";
    };

    wantedBy = [ "multi-user.target" ];
  };
}

