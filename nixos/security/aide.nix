{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  dbPath = "/var/lib/aide/aide.db";
  dbNewPath = "/var/lib/aide/aide.db.new";
  # Watched trees minus state that changes on its own, which otherwise fails
  # every daily check (seen on elara and mars): the random seed, timer stamps,
  # the letsencrypt symlink link-letsencrypt recreates on start, shell history
  # and Docker/buildx client state under /root, and logs left in /root. The
  # container data trees are listed too in case a watched path ever covers
  # them. AIDE matches these as regular expressions.
  configFile = pkgs.writeText "aide.conf" ''
    database_in=file:${dbPath}
    database_out=file:${dbNewPath}
    /etc p+i+u+g+sha256
    /root p+i+u+g+sha256
    /var/lib/systemd p+i+u+g+sha256
    !/etc/nixos/\.git
    !/etc/nixos/result
    !/etc/letsencrypt
    !/var/lib/systemd/random-seed$
    !/var/lib/systemd/timers
    !/var/lib/systemd/coredump
    !/var/lib/systemd/catalog
    !/var/lib/systemd/backlight
    !/var/lib/systemd/pstore
    !/var/lib/systemd/timesync
    !/root/\.docker
    !/root/\.cache
    !/root/\.local/share
    !/root/\.[a-z]*_history$
    !/root/\.zcompdump
    !/root/\.lesshst$
    !/root/\.viminfo$
    !/root/[^/]*\.log$
    !/var/lib/docker
    !/var/lib/pterodactyl
    !/data/coolify
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
    ${pkgs.util-linux}/bin/logger -t homelab-aide "AIDE database initialized on ${cfg.hostName}"
  '';
  aideCheck = pkgs.writeShellScript "aide-check" ''
    set -euo pipefail
    if [ ! -f ${dbPath} ]; then
      echo "AIDE database missing; run aide-init first" >&2
      exit 1
    fi
    if ${pkgs.aide}/bin/aide --config=${configFile} --check; then
      ${pkgs.util-linux}/bin/logger -t homelab-aide "AIDE check passed on ${cfg.hostName}"
    else
      ${pkgs.util-linux}/bin/logger -t homelab-aide "AIDE check FAILED on ${cfg.hostName}"
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

    # Re-baseline on every activation (boot and switch), after /etc has been
    # rebuilt: a rebuild legitimately rewrites /etc, and a baseline taken
    # before the "etc" step left every later check failing. The config file
    # path is part of this script, so changing the exclusions above also
    # re-baselines.
    system.activationScripts.homelabAideInit = lib.stringAfter [ "users" "etc" ] ''
      ${aideInit} || true
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/aide 0700 root root -"
      "d /var/log/aide 0750 root root -"
    ];
  };
}
