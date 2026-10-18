{ config, pkgs, lib, inputs, ... }:

let
  cfg = config.homelab.security;
  sops-path = builtins.toString inputs.nix-secrets;
  backupDir = cfg.cisco.backupDir;
  backupScript = pkgs.writeShellScript "cisco-config-backup" ''
    set -euo pipefail
    BACKUP_DIR="${backupDir}"
    KEY="${config.sops.secrets."cisco-ssh-key".path}"
    ENABLE="${config.sops.secrets."cisco-enable-password".path}"
    SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$BACKUP_DIR/known_hosts -i $KEY"
    SSH_LEGACY="-o KexAlgorithms=+diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
    TS="$(date -u +%Y%m%dT%H%MZ)"
    DRIFT=0

    mkdir -p "$BACKUP_DIR/astracap" "$BACKUP_DIR/astraquasar"

    run_device() {
      local name="$1"
      local host="$2"
      local user="$3"
      local out="$BACKUP_DIR/$name/running-config-$TS.txt"
      local latest="$BACKUP_DIR/$name/running-config-latest.txt"
      local prev="$BACKUP_DIR/$name/running-config-previous.txt"

      {
        echo "enable"
        cat "$ENABLE"
        echo "terminal length 0"
        echo "show running-config"
      } | ${pkgs.openssh}/bin/ssh $SSH_OPTS $SSH_LEGACY "$user@$host" > "$out"

      if [ -f "$latest" ]; then
        cp "$latest" "$prev"
        if ! diff -q "$prev" "$out" >/dev/null 2>&1; then
          DRIFT=1
          logger -t cisco-config-backup "$name running-config changed since last backup"
        fi
      fi
      cp "$out" "$latest"
    }

    run_device astracap ${cfg.cisco.astracapHost} prestonh
    run_device astraquasar ${cfg.cisco.astraquasarHost} admin

    OUT="/var/lib/node-exporter-textfile/homelab_cisco_config_drift.prom"
    {
      echo "# HELP homelab_cisco_config_drift 1 when Cisco running-config differs from previous backup"
      echo "# TYPE homelab_cisco_config_drift gauge"
      echo "homelab_cisco_config_drift  $DRIFT"
    } > "$OUT"
  '';
in {
  config = lib.mkIf (cfg.enable && cfg.cisco.backup.enable && cfg.role == "central") {
    sops.secrets = {
      "cisco-ssh-key" = {
        sopsFile = "${sops-path}/secrets/cisco.yaml";
        key = "cisco-ssh-key";
        mode = "0400";
      };
      "cisco-enable-password" = {
        sopsFile = "${sops-path}/secrets/cisco.yaml";
        key = "cisco-enable-password";
        mode = "0400";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${backupDir} 0750 root root -"
      "d ${backupDir}/astracap 0750 root root -"
      "d ${backupDir}/astraquasar 0750 root root -"
    ];

    systemd.services.cisco-config-backup = {
      description = "Backup Astracap and Astraquasar running-config via SSH";
      after = [ "network-online.target" "sops-nix.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = backupScript;
      };
    };

    systemd.timers.cisco-config-backup = {
      description = "Daily Cisco running-config backup and diff";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "45min";
        Persistent = true;
        Unit = "cisco-config-backup.service";
      };
    };
  };
}
