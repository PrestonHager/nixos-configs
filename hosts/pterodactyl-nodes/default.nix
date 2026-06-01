{ config, inputs, pkgs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  imports = [
    #./samba.nix
    ./nfs.nix
    ../../nixos
    ../../nixos/headless
    # hardware configuration for the Dell Workstations
    ../../hardware/dell-optiplex-7050/hardware-configuration.nix
    # include any users
    ../../users/prestonh
  ];

  # Secrets for samba share password
  sops.secrets = {
    "crux-samba" = {
      sopsFile = "${sops-path}/secrets/crux.yaml";
      mode = "0640";
    };
    "pterodactyl-db-password" = {
      sopsFile = "${sops-path}/secrets/pterodactyl.yaml";
      mode = "0400";
    };
  };

  # Enable docker for wings backend
  virtualisation.docker = {
    enable = true;
  };

  environment.systemPackages = [
    inputs.pterodactyl-wings.packages.x86_64-linux.wings
    pkgs.cifs-utils # for the samba client
  ];

  # Create systemd service for the wings binary
  systemd.tmpfiles.rules = [
    "d /etc/pterodactyl 0750 pterodactyl pterodactyl -"
  ];
  systemd.services.wings = {
    enable = true;
    description = "Daemon for the Pterodactyl Wings binary";

    unitConfig = {
      After = [ "docker.service" ];
    };

    serviceConfig = {
      User = "pterodactyl";
      Group = "pterodactyl";
      WorkingDirectory = "/etc/pterodactyl";
      ExecStart = "${inputs.pterodactyl-wings.packages.x86_64-linux.wings}/bin/wings";
      RuntimeDirectory = "wings";
      RuntimeDirectoryMode = "0755";
      PIDFile = "/var/run/wings/daemon.pid";
      Restart = "on-failure";
    };

    wantedBy = [ "multi-user.target" ];
  };

  # Create pterodactyl user for wings daemon
  # It has groups systemd-journal and pterodactyl
  users.users = {
    pterodactyl = {
      isSystemUser = true;
      group = "users";
      extraGroups = [ "systemd-journal" "pterodactyl" ];
    };
  };
  users.groups = {
    "pterodactyl" = {};
  };

  # Add MariaDB server for database backend
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    dataDir = "/var/lib/mysql";
    settings.mysqld = {
      sql_mode = "NO_ENGINE_SUBSTITUTION";
      bind_address = "0.0.0.0";
      port = 3306;
    };
  };
  # systemd oneshot to ensure remote user/password/grants using the secret file at runtime
  systemd.services."mysql-set-pterodactyl-password" = {
    description = "Ensure MariaDB user/password for pterodactyl";
    after = [ "mysql.service" ];
    requires = [ "mysql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "set-pterodactyl-db-password" ''
        PASS=$(cat ${config.sops.secrets."pterodactyl-db-password".path})

        {
          printf "CREATE USER IF NOT EXISTS 'pterodactyl'@'%%' IDENTIFIED BY '%s';\n" "$PASS"
          printf "ALTER USER 'pterodactyl'@'%%' IDENTIFIED BY '%s';\n" "$PASS"
          printf "GRANT USAGE ON *.* TO 'pterodactyl'@'%%';\n"
          printf "GRANT ALL PRIVILEGES ON *.* TO 'pterodactyl'@'%%' WITH GRANT OPTION;\n"
          printf "FLUSH PRIVILEGES;\n"
        } | ${pkgs.mariadb}/bin/mysql -u root
      '';
      # ensure systemd re-runs this unit when the secret file path changes
      Restart = "no";
    };
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      config.sops.secrets."pterodactyl-db-password".path
    ];
  };

  # Add ports from /etc/pterodactyl/config.yml to firewall
  networking.firewall = {
    enable = false;
    #allowedTCPPorts = [ 8443 2022 ];
    #allowedUDPPorts = [ 8443 2022 ];
  };

  # Link the letsencrypt files to the file share after it has been mounted
  systemd.services.link-letsencrypt = {
    description = "Link Let's Encrypt files from NFS";
    after = [ "mnt-pterodactyl\\x2dshare.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "link-letsencrypt" ''
        mkdir -p /etc/letsencrypt
        ln -sfn /mnt/pterodactyl-share/letsencrypt /etc/letsencrypt/live
        ln -sfn /mnt/pterodactyl-share/letsencrypt-archive /var/lib/letsencrypt
        ln -sfn /mnt/pterodactyl-share/letsencrypt.log /var/log/letsencrypt.log
      '';
      RemainAfterExit = true;
    };
  };
}

