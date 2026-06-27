{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.security;
  centralScrapes = lib.optionalString (cfg.role == "central") ''
      - job_name: suricata
        static_configs:
          - targets: [localhost]
            labels:
              job: suricata
              host: ${cfg.hostName}
              __path__: /var/log/suricata/eve.json
      - job_name: cisco-syslog
        static_configs:
          - targets: [localhost]
            labels:
              job: cisco-syslog
              host: ace
              __path__: /var/log/cisco-syslog/cisco.log
      - job_name: technitium-dns
        static_configs:
          - targets: [localhost]
            labels:
              job: technitium-dns
              host: ace
              __path__: /stor/technitium/logs/*.log
  '';
  promtailYaml = pkgs.writeText "promtail-config.yaml" ''
    server:
      http_listen_port: 9080
      grpc_listen_port: 0
    positions:
      filename: /var/lib/promtail/positions.yaml
    clients:
      - url: ${cfg.lokiUrl}/loki/api/v1/push
    scrape_configs:
      - job_name: journal
        journal:
          max_age: 12h
          labels:
            job: systemd-journal
            host: ${cfg.hostName}
        relabel_configs:
          - source_labels: ['__journal__systemd_unit']
            target_label: unit
          - source_labels: ['__journal__systemd_unit']
            target_label: systemd_unit
          - source_labels: ['__journal_priority_keyword']
            target_label: level
      - job_name: audit
        static_configs:
          - targets: [localhost]
            labels:
              job: audit
              host: ${cfg.hostName}
              __path__: /var/log/audit/audit.log
${centralScrapes}
  '';
in {
  options.homelab.security.promtail = {
    enable = lib.mkEnableOption "Promtail log shipper to central Loki";
  };

  config = lib.mkIf (cfg.enable && cfg.promtail.enable) {
    systemd.services.promtail = {
      description = "Promtail log shipper for Loki";
      after = [ "network-online.target" "systemd-journald.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "promtail";
        Group = "promtail";
        SupplementaryGroups = [ "systemd-journal" "audit" ] ++ lib.optionals (cfg.role == "central") [ "suricata" ];
        ExecStart = "${pkgs.promtail}/bin/promtail -config.file=${promtailYaml}";
        Restart = "on-failure";
        ReadWritePaths = [ "/var/lib/promtail" ];
      };
    };

    users.users.promtail = {
      isSystemUser = true;
      group = "promtail";
      extraGroups = [ "systemd-journal" ];
    };
    users.groups.promtail = { };

    systemd.tmpfiles.rules = [
      "d /var/lib/promtail 0750 promtail promtail -"
    ];
  };
}
