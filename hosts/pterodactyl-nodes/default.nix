{ config, inputs, pkgs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in
{
  imports = [
    ./link-letsencrypt.nix
    ./nfs.nix
    ../../nixos
    ../../nixos/headless
    ../../hardware/dell-optiplex-7050/hardware-configuration.nix
    ../../users/prestonh
  ];

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

  virtualisation.docker.enable = true;

  environment.systemPackages = [
    inputs.pterodactyl-wings.packages.x86_64-linux.wings
    pkgs.cifs-utils
  ];

  systemd.tmpfiles.rules = [
    "d /etc/pterodactyl 0750 pterodactyl pterodactyl -"
    "d /var/lib/pterodactyl 0750 pterodactyl pterodactyl -"
    "d /var/lib/pterodactyl/volumes 0750 pterodactyl pterodactyl -"
    "d /var/lib/pterodactyl/archives 0750 pterodactyl pterodactyl -"
    "d /var/lib/pterodactyl/backups 0750 pterodactyl pterodactyl -"
    "d /var/log/pterodactyl 0750 pterodactyl pterodactyl -"
    "d /var/log/pterodactyl/install 0750 pterodactyl pterodactyl -"
  ];

  systemd.services.pterodactyl-config-perms = {
    description = "Ensure Wings can read /etc/pterodactyl/config.yml";
    before = [ "wings.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "pterodactyl-config-perms" ''
        if [ -f /etc/pterodactyl/config.yml ]; then
          chown pterodactyl:pterodactyl /etc/pterodactyl/config.yml
          chmod 0640 /etc/pterodactyl/config.yml
        fi
        if [ -d /var/lib/pterodactyl ]; then
          chown -R pterodactyl:pterodactyl /var/lib/pterodactyl
          find /var/lib/pterodactyl -type d -exec chmod 0750 {} \;
          find /var/lib/pterodactyl -type f -exec chmod 0640 {} \;
        fi
        if [ -d /var/log/pterodactyl ]; then
          chown -R pterodactyl:pterodactyl /var/log/pterodactyl
          find /var/log/pterodactyl -type d -exec chmod 0750 {} \;
          find /var/log/pterodactyl -type f -exec chmod 0640 {} \;
        fi
      '';
      RemainAfterExit = true;
    };
  };

  systemd.services.wings = {
    enable = true;
    description = "Daemon for the Pterodactyl Wings binary";
    unitConfig = {
      After = [
        "docker.service"
        "link-letsencrypt.service"
        "pterodactyl-config-perms.service"
      ];
      Requires = [
        "link-letsencrypt.service"
        "pterodactyl-config-perms.service"
      ];
    };
    serviceConfig = {
      User = "pterodactyl";
      Group = "pterodactyl";
      WorkingDirectory = "/etc/pterodactyl";
      ExecStart = "${inputs.pterodactyl-wings.packages.x86_64-linux.wings}/bin/wings";
      RuntimeDirectory = "wings";
      RuntimeDirectoryMode = "0755";
      PIDFile = "/var/run/wings/daemon.pid";
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      Restart = "on-failure";
    };
    wantedBy = [ "multi-user.target" ];
  };

  users.users.pterodactyl = {
    isSystemUser = true;
    group = "pterodactyl";
    extraGroups = [ "systemd-journal" "docker" ];
  };
  users.groups.pterodactyl = { };

  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    dataDir = "/var/lib/mysql";
    settings.mysqld = {
      sql_mode = "NO_ENGINE_SUBSTITUTION";
      bind_address = "127.0.0.1";
      port = 3306;
    };
  };

  systemd.services."mysql-set-pterodactyl-password" = {
    description = "Ensure MariaDB user/password for pterodactyl";
    after = [ "mysql.service" ];
    requires = [ "mysql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = pkgs.writeShellScript "set-pterodactyl-db-password" ''
        PASS="$(cat ${config.sops.secrets."pterodactyl-db-password".path})"
        PASS_ESC="$(printf '%s' "$PASS" | sed "s/'/''''/g")"
        {
          printf "CREATE DATABASE IF NOT EXISTS pterodactyl;\n"
          printf "DROP USER IF EXISTS 'pterodactyl'@'%%';\n"
          printf "CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY '%s';\n" "$PASS_ESC"
          printf "ALTER USER 'pterodactyl'@'localhost' IDENTIFIED BY '%s';\n" "$PASS_ESC"
          printf "GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'localhost';\n"
          printf "FLUSH PRIVILEGES;\n"
        } | ${pkgs.mariadb}/bin/mysql -u root
      '';
      Restart = "no";
    };
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      config.sops.secrets."pterodactyl-db-password".path
    ];
  };

  networking.firewall = {
    enable = true;
    checkReversePath = "loose";
    allowedTCPPorts = [ 22 443 2022 ];
    extraCommands = ''
      iptables -A nixos-fw -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept
    '';
  };
}
