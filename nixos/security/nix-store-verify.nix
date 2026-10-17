{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  textfileDir = "/var/lib/node-exporter-textfile";
  verifyScript = pkgs.writeShellScript "homelab-nix-store-verify" ''
    set -euo pipefail
    HOST="${cfg.hostName}"
    OUT="${textfileDir}/homelab_nix_store_verify.prom"
    result=0
    if ! ${pkgs.nix}/bin/nix-store --verify --check-contents 2>/tmp/nix-store-verify.log; then
      result=1
      logger -t homelab-nix-store "verify failed on $HOST: $(head -3 /tmp/nix-store-verify.log)"
    fi
    {
      echo "# HELP homelab_nix_store_verify_failed 1 when nix-store --verify reports corruption"
      echo "# TYPE homelab_nix_store_verify_failed gauge"
      echo "homelab_nix_store_verify_failed{host=\"$HOST\"} $result"
    } > "$OUT"
  '';
in {
  config = lib.mkIf (cfg.enable && cfg.phase2.enable) {
    systemd.services.homelab-nix-store-verify = {
      description = "Weekly nix-store integrity verification";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = verifyScript;
      };
    };

    systemd.timers.homelab-nix-store-verify = {
      description = "Run nix-store --verify weekly";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun 03:30";
        RandomizedDelaySec = "30min";
        Persistent = true;
        Unit = "homelab-nix-store-verify.service";
      };
    };
  };
}
