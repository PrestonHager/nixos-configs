{ config, pkgs, lib, ... }:
let
  promCfg = import ./prometheus-config.nix { inherit lib; };
  grafanaDashboards = ./grafana/dashboards;
in {
  imports = [
    ./exporters.nix
    ./ace-health-exporter.nix
  ];

  environment.etc."prometheus/prometheus.yml".text = promCfg.prometheusYml;
  environment.etc."prometheus/blackbox.yml".source = ./blackbox.yml;

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
          path: /etc/grafana/dashboards
  '';

  environment.etc."grafana/dashboards/ace-overview.json".source = "${grafanaDashboards}/ace-overview.json";
  environment.etc."grafana/dashboards/ace-services.json".source = "${grafanaDashboards}/ace-services.json";
  environment.etc."grafana/dashboards/ace-uptime.json".source = "${grafanaDashboards}/ace-uptime.json";
  environment.etc."grafana/dashboards/ace-http-probes.json".source = "${grafanaDashboards}/ace-http-probes.json";
  environment.etc."grafana/dashboards/ace-tcp-probes.json".source = "${grafanaDashboards}/ace-tcp-probes.json";
}