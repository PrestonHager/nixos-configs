{ config, pkgs, lib, ... }:
let
  blackboxCfg = import ./blackbox-config.nix { inherit lib; };
  grafanaDashboards = ./grafana/dashboards;
in {
  imports = [
    ./exporters.nix
    ./ace-health-exporter.nix
    ./ace-version-check.nix
    ./ace-service-auto-update.nix
    ./lan-dns-prober.nix
    ./grafana-alerting.nix
    ./loki.nix
    ./promtail.nix
    ./suricata.nix
    ./grafana-security-alerting.nix
  ];

  environment.etc."prometheus/prometheus.yml".text = (import ./prometheus-config.nix { inherit lib; }).prometheusYml;
  environment.etc."prometheus/blackbox.yml".text = blackboxCfg.blackboxYml;

  environment.etc."grafana/provisioning/datasources/prometheus.yaml".text = ''
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        orgId: 1
        access: proxy
        url: http://host.containers.internal:9090
        isDefault: true
        editable: false
        jsonData:
          timeInterval: 15s
          httpMethod: POST
      - name: Prometheus (crux)
        type: prometheus
        uid: prometheus-crux
        orgId: 1
        access: proxy
        url: http://192.168.5.6:9090
        isDefault: false
        editable: false
        jsonData:
          timeInterval: 15s
          httpMethod: POST
  '';

  environment.etc."grafana/provisioning/dashboards/ace.yaml".text = ''
    apiVersion: 1
    providers:
      - name: Ace
        orgId: 1
        folder: Ace
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /etc/grafana/dashboards/ace
  '';

  environment.etc."grafana/provisioning/dashboards/crux.yaml".text = ''
    apiVersion: 1
    providers:
      - name: Crux
        orgId: 1
        folder: Crux
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /etc/grafana/dashboards/crux
  '';

  environment.etc."grafana/provisioning/dashboards/lan.yaml".text = ''
    apiVersion: 1
    providers:
      - name: LAN
        orgId: 1
        folder: LAN
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /etc/grafana/dashboards/lan
  '';

  environment.etc."grafana/dashboards/ace/ace-overview.json".source = "${grafanaDashboards}/ace-overview.json";
  environment.etc."grafana/dashboards/ace/ace-services.json".source = "${grafanaDashboards}/ace-services.json";
  environment.etc."grafana/dashboards/ace/ace-uptime.json".source = "${grafanaDashboards}/ace-uptime.json";
  environment.etc."grafana/dashboards/ace/ace-http-probes.json".source = "${grafanaDashboards}/ace-http-probes.json";
  environment.etc."grafana/dashboards/ace/ace-tcp-probes.json".source = "${grafanaDashboards}/ace-tcp-probes.json";
  environment.etc."grafana/dashboards/ace/ace-versions.json".source = "${grafanaDashboards}/ace-versions.json";
  environment.etc."grafana/dashboards/crux/crux-uptime.json".source = "${grafanaDashboards}/crux-uptime.json";
  environment.etc."grafana/dashboards/crux/crux-http-probes.json".source = "${grafanaDashboards}/crux-http-probes.json";
  environment.etc."grafana/dashboards/lan/lan-status.json".source = "${grafanaDashboards}/lan-status.json";
}