{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  dbPath = "/var/lib/aide/aide.db";
  dbNewPath = "/var/lib/aide/aide.db.new";
  configFile = pkgs.writeText "aide.conf" ''
    @@define DBFILE ${dbPath}
    @@define DATABASE_OUT ${dbNewPath}
    @@define LOGFILE /var/log/aide/aide.log
    /etc p+i+u+g+sha256
    /root p+i+u+g+sha256
    !/etc/nixos/.git
    !/etc/nixos/result
    /var/lib/systemd p+i+u+g+sha256
  '';
  aideInit = pkgs.writeShellScript "aide-init" ''
    set -euo pipefail
    mkdir -p /var/lib/aide /var/log/aide
    ${pkgs.aide}/bin/aide --config=${configFile} --init
    if [ -f ${dbNewPath} ]; then
      mv -f ${dbNewPath} ${dbPath}
    elif [ -f /etc/aide.db.new ]; then
      mv -f /etc/aide.db.new ${dbPath}
    else
      echo "AIDE init did not produce expected database output" >&2
      exit 1
    fi
    logger -t homelab-aide "AIDE database initialized on ${cfg.hostName}"
  '';
  aideCheck = pkgs.writeShellScript "aide-check" ''
    set -euo pipefail
    if [ ! -f ${dbPath} ]; then
      echo "AIDE database missing; run aide-init first" >&2
      exit 1
    fi
    if ${pkgs.aide}/bin/aide --config=${configFile} --check; then
      logger -t homelab-aide "AIDE check passed on ${cfg.hostName}"
    else
      logger -t homelab-aide "AIDE check FAILED on ${cfg.hostName}"
      exit 1
    fi
  '';
in {
  config = lib.mkIf (cfg.enable && cfg.phase2.enable) {
    systemd.services.aide-init = {
      description = "Initialize AIDE integrity database";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = aideInit;
      };
    };

    systemd.services.aide-check = {
      description = "AIDE integrity check";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = aideCheck;
      };
    };

    systemd.timers.aide-check = {
      description = "Daily AIDE integrity check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "45min";
        OnUnitActiveSec = "24h";
        RandomizedDelaySec = "30min";
        Unit = "aide-check.service";
      };
    };

    system.activationScripts.homelabAideInit = lib.stringAfter [ "users" ] ''
      ${aideInit} || true
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/aide 0700 root root -"
      "d /var/log/aide 0750 root root -"
    ];
  };
}
