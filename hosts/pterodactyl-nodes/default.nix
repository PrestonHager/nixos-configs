{ config, inputs, pkgs, lib, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  host = config.networking.hostName;
  bootstrapPubkey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAZG4s8GtqKZoahIUsFwbXsMnuUrrlSDmN2nzt39pDiS bootstrap@homelab";
  # root@ace's automation key (nixos/ace-git-identity.nix): only from ace
  # itself, and never for forwarding.
  aceDeployPubkey =
    ''from="192.168.5.5",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEMydexGEchoOPoh8jDiecyTkmgj/Tfxap7U+lQQfPW root@ace (nixos-configs automation)'';
in
{
  imports = [
    ./link-letsencrypt.nix
    ./nfs.nix
    ../../nixos
    ../../nixos/security
    # Ace headless imports podman/containers/monitoring — incompatible with Wings (Docker).
    ../../users/prestonh
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # root@ace deploys the nodes (nixos-rebuild --target-host, nix copy) with its
  # own key from nixos/ace-git-identity.nix, so no workstation agent forwarding.
  users.users.root.openssh.authorizedKeys.keys = [ bootstrapPubkey aceDeployPubkey ];
  users.users.prestonh.openssh.authorizedKeys.keys = [ bootstrapPubkey ];
  # Only the keys declared here count; stray ~/.ssh/authorized_keys files are
  # ignored (nixos/security/ssh.nix). bootstrapPubkey is the admin
  # workstation's key, so this cannot lock the workstation out.
  homelab.security.ssh.declarativeKeysOnly = true;

  sops.secrets = {
    "pterodactyl-db-password" = {
      sopsFile = "${sops-path}/secrets/pterodactyl.yaml";
      mode = "0400";
    };
  } // lib.optionalAttrs (host == "crux") {
    "crux-samba" = {
      sopsFile = "${sops-path}/secrets/crux.yaml";
      mode = "0640";
    };
  };

  virtualisation.docker = {
    enable = true;
    # Keep game-server containers running when dockerd restarts on a rebuild
    # (nixpkgs defaults this to false).
    liveRestore = true;
  };

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
    description = "Ensure Wings ownership on config and server volumes";
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
          # Docker install/start runs as root and leaves root-owned files Wings cannot write.
          chown -R pterodactyl:pterodactyl /var/lib/pterodactyl
          # `{} +` batches paths into a few chmods: one exec per file every
          # 5 minutes flooded the root-exec audit rule (nixos/security/audit.nix).
          find /var/lib/pterodactyl -type d -exec chmod 0750 {} +
          find /var/lib/pterodactyl -maxdepth 1 -type f -exec chmod 0640 {} +
          find /var/lib/pterodactyl/archives /var/lib/pterodactyl/backups -type f -exec chmod 0640 {} + 2>/dev/null || true
          find /var/lib/pterodactyl/volumes -type f -name '*.sh' -exec chmod u+x {} + 2>/dev/null || true
          find /var/lib/pterodactyl/volumes -type f -name VintagestoryServer -exec chmod u+x {} + 2>/dev/null || true
        fi
        if [ -d /var/log/pterodactyl ]; then
          chown -R pterodactyl:pterodactyl /var/log/pterodactyl
          find /var/log/pterodactyl -type d -exec chmod 0750 {} +
          find /var/log/pterodactyl -type f -exec chmod 0640 {} +
        fi
      '';
      RemainAfterExit = true;
    };
  };

  systemd.timers.pterodactyl-config-perms = {
    description = "Reconcile Pterodactyl volume ownership after Docker installs";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services.wings = {
    enable = true;
    description = "Daemon for the Pterodactyl Wings binary";
    # The TLS key is read through /etc/letsencrypt/live -> /mnt/pterodactyl-share
    # (NFS from ace; link-letsencrypt.nix, nfs.nix). Wants, not Requires: a
    # failed requirement fails Wings with result 'dependency', which Restart=
    # never retries, so one NFS hiccup at boot or during a switch would leave
    # Wings down for good. With Wants, Wings still starts after them, fails on
    # an unreadable key, and retries below until link-letsencrypt (which
    # retries the mount itself) has the share back. Wants also stops a restart
    # of either oneshot during a rebuild from bouncing Wings.
    after = [
      "docker.service"
      "link-letsencrypt.service"
      "pterodactyl-config-perms.service"
    ];
    wants = [
      "link-letsencrypt.service"
      "pterodactyl-config-perms.service"
    ];
    # Supplementary groups are fixed when the process starts, and a group
    # change alone does not change this unit, so a switch would leave a running
    # Wings without its new groups. `users` is what lets it read its 0640
    # root:users key, so restart Wings whenever its groups change.
    restartTriggers = [
      (lib.concatStringsSep "," config.users.users.pterodactyl.extraGroups)
    ];
    # (StartLimitBurst - 1) * RestartSec = 90s > StartLimitIntervalSec, so the
    # automatic restarts below can never hit the start limit (the old 100ms
    # default burned all 5 starts in 3s and left Wings down); only a tight
    # manual start loop can.
    startLimitIntervalSec = 60;
    startLimitBurst = 10;
    serviceConfig = {
      User = "pterodactyl";
      Group = "pterodactyl";
      WorkingDirectory = "/etc/pterodactyl";
      ExecStart = "${inputs.pterodactyl-wings.packages.x86_64-linux.wings}/bin/wings";
      RuntimeDirectory = "wings";
      RuntimeDirectoryMode = "0755";
      PIDFile = "/run/wings/daemon.pid";
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      Restart = "on-failure";
      RestartSec = 10;
    };
    wantedBy = [ "multi-user.target" ];
  };

  users.users.pterodactyl = {
    isSystemUser = true;
    group = "pterodactyl";
    # `users` (gid 100): node TLS keys arrive over NFS as 0640 root:users
    # (nixos/caddy/certificates.nix), and Wings must read its own key.
    extraGroups = [ "systemd-journal" "docker" "users" ];
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

  # Game containers get the internet only: no LAN, no tailnet, no services on
  # the node itself (nixos/security/container-egress.nix). pterodactyl0 is
  # Wings' pterodactyl_nw; docker0 and br+ cover Docker's default and any
  # other networks. Wings hands containers public resolvers (1.1.1.1/1.0.0.1,
  # docker.network.dns in /etc/pterodactyl/config.yml), so DNS needs no LAN
  # exception.
  homelab.security.containerEgress = {
    enable = true;
    bridges = [ "pterodactyl0" "docker0" "br+" ];
  };

  homelab.security = {
    enable = true;
    hostName = config.networking.hostName;
    role = "node";
    phase2.enable = true;
    promtail.enable = true;
  };
}
