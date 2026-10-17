{ pkgs, lib, ... }:
let
  lanResolver = "192.168.5.5";
  expectedA = "192.168.5.5";
  dnsHosts = [
    "grafana.prestonhager.com"
    "panel.prestonhager.com"
    "dns.prestonhager.com"
    "cloud.prestonhager.com"
    "matrix.prestonhager.com"
    "zitadel.prestonhager.com"
    "ace.internal.prestonhager.com"
  ];
  probeScript = pkgs.writeShellScript "lan-dns-probe" ''
    set -euo pipefail
    OUT_DIR="/var/lib/node-exporter-textfile"
    OUT_FILE="''${OUT_DIR}/lan_dns_probe.prom"
    TMP="''${OUT_FILE}.$$"
    mkdir -p "$OUT_DIR"
    {
      echo '# HELP ace_dns_probe_success Whether Technitium DNS returns the expected LAN A record (1=yes).'
      echo '# TYPE ace_dns_probe_success gauge'
      echo '# HELP ace_dns_probe_responder Which nameserver answered the query.'
      echo '# TYPE ace_dns_probe_responder gauge'
      for host in ${lib.concatStringsSep " " dnsHosts}; do
        answer=""
        next="$host"
        for _ in 1 2 3 4 5; do
          raw="$(dig +short "@${lanResolver}" "$next" 2>/dev/null | head -1 | sed 's/\.$//' || true)"
          if [[ -z "$raw" ]]; then
            break
          fi
          if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            answer="$raw"
            break
          fi
          next="$raw"
        done
        if [[ "$answer" == "${expectedA}" ]]; then
          success=1
        else
          success=0
        fi
        echo "ace_dns_probe_success{hostname=\"$host\",resolver=\"${lanResolver}\",expected=\"${expectedA}\"} $success"
        if [[ -n "$answer" ]]; then
          echo "ace_dns_probe_responder{hostname=\"$host\",answer=\"$answer\"} 1"
        fi
      done
    } > "$TMP"
    chown node_exporter:node_exporter "$TMP" 2>/dev/null || true
    mv "$TMP" "$OUT_FILE"
    chown node_exporter:node_exporter "$OUT_FILE" 2>/dev/null || true
  '';
in {
  systemd.services.lan-dns-prober = {
    description = "Export Technitium DNS split-horizon probe metrics";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ bash bind dig ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = probeScript;
    };
  };

  systemd.timers.lan-dns-prober = {
    description = "Run Technitium DNS probe every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "1min";
      Unit = "lan-dns-prober.service";
    };
  };
}
