{ config, lib, ... }:

let
  cfg = config.homelab.security;
  alertingDir = ./grafana/provisioning/alerting;
in {
  config = lib.mkIf (cfg.enable && cfg.role == "central" && cfg.phase2.enable) {
    environment.etc."grafana/provisioning/alerting/security-alert-rules.yaml".source =
      "${alertingDir}/security-alert-rules.yaml";

    environment.etc."grafana/provisioning/datasources/loki.yaml".text = ''
      apiVersion: 1
      datasources:
        - name: Loki
          type: loki
          uid: loki
          orgId: 1
          access: proxy
          url: http://127.0.0.1:3100
          isDefault: false
          editable: false
          jsonData:
            maxLines: 1000
    '';
  };
}
