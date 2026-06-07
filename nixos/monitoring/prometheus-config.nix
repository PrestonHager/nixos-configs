{ lib, ... }:
let
  hostGateway = "10.88.0.1";
  httpTargets = [
    "https://panel.prestonhager.com/"
    "https://test.panel.prestonhager.com/"
    "https://grafana.prestonhager.com/"
    "https://jellyfin.prestonhager.com/"
    "https://vault.prestonhager.com/"
    "https://wg.prestonhager.com/"
    "https://prometheus.prestonhager.com/"
    "https://loftiawiki.org/"
    "https://upgrade.loftiawiki.org/"
    "https://matrix.prestonhager.com/"
    "https://zitadel.prestonhager.com/"
    "https://cloud.prestonhager.com/"
    "https://dns.prestonhager.com/"
    "http://127.0.0.1/"
  ];
  tcpTargets = [
    "127.0.0.1:9001"
    "127.0.0.1:9002"
    "127.0.0.1:80"
    "127.0.0.1:443"
  ];
  mkRelabel = module: [
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target" ];
      target_label = "instance";
    }
    {
      source_labels = [ "__param_module" ];
      target_label = "module";
    }
    {
      target_label = "__address__";
      replacement = "${hostGateway}:9115";
    }
  ];
in {
  prometheusYml = lib.generators.toYAML { } {
    global = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
    };
    scrape_configs = [
      {
        job_name = "prometheus";
        static_configs = [{ targets = [ "localhost:9090" ]; }];
      }
      {
        job_name = "node";
        static_configs = [{ targets = [ "${hostGateway}:9100" ]; }];
      }
      {
        job_name = "caddy";
        metrics_path = "/metrics";
        static_configs = [{ targets = [ "${hostGateway}:2019" ]; }];
      }
      {
        job_name = "grafana";
        metrics_path = "/metrics";
        static_configs = [{ targets = [ "${hostGateway}:8082" ]; }];
      }
      {
        job_name = "blackbox-http";
        metrics_path = "/probe";
        params = { module = [ "http_2xx" ]; };
        static_configs = [{ targets = httpTargets; }];
        relabel_configs = mkRelabel "http_2xx";
      }
      {
        job_name = "blackbox-tcp";
        metrics_path = "/probe";
        params = { module = [ "tcp_connect" ]; };
        static_configs = [{ targets = tcpTargets; }];
        relabel_configs = mkRelabel "tcp_connect";
      }
      {
        job_name = "wg-portal";
        scrape_interval = "60s";
        static_configs = [{ targets = [ "metrics.wg.prestonhager.com" ]; }];
      }
    ];
  };
}
