{ lib, ... }:
let
  hostGateway = "10.88.0.1";
  lanIp = "192.168.5.5";
  cruxBlackbox = "192.168.5.6:9115";
  cruxBlackboxCfg = import ./crux-blackbox-config.nix { inherit lib; };

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
    "https://matrix.prestonhager.com/_matrix/client/versions"
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

  lanHttpsTargets = cruxBlackboxCfg.lanHttpTargets;

  mkBlackboxRelabel = extra: [
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
  ] ++ extra;

  mkCruxBlackboxRelabel = [
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
      source_labels = [ "vhost" ];
      target_label = "vhost";
    }
    {
      target_label = "__address__";
      replacement = cruxBlackbox;
    }
    {
      target_label = "probe_location";
      replacement = "lan";
    }
    {
      target_label = "probe_source";
      replacement = "crux";
    }
  ];

  lanHttpStaticConfigs = [
    {
      targets = lanHttpsTargets;
      labels = {
        __param_module = "http_2xx";
        probe_location = "lan";
        probe_source = "crux";
      };
    }
    {
      targets = [ "http://${lanIp}/" ];
      labels = {
        __param_module = "http_local";
        probe_location = "lan";
        probe_source = "crux";
      };
    }
  ];

  lanDnsStaticConfigs = map (entry: {
    targets = [ lanIp ];
    labels = {
      __param_module = entry.module;
      instance = "dns://${lanIp}/${entry.host}";
      probe_location = "lan";
      probe_source = "crux";
      vhost = entry.host;
    };
  }) cruxBlackboxCfg.lanDnsChecks;

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
        job_name = "pushgateway-external";
        honor_labels = true;
        static_configs = [{
          targets = [ "${hostGateway}:9091" ];
          labels = { probe_location = "external"; };
        }];
      }
      {
        job_name = "blackbox-http";
        metrics_path = "/probe";
        params = { module = [ "http_2xx" ]; };
        static_configs = [{
          targets = httpTargets;
          labels = { probe_location = "local"; };
        }];
        relabel_configs = mkBlackboxRelabel [
          {
            target_label = "probe_location";
            replacement = "local";
          }
        ];
      }
      {
        job_name = "blackbox-http-lan";
        metrics_path = "/probe";
        static_configs = lanHttpStaticConfigs;
        relabel_configs = mkCruxBlackboxRelabel;
      }
      {
        job_name = "blackbox-dns-lan";
        metrics_path = "/probe";
        static_configs = lanDnsStaticConfigs;
        relabel_configs = mkCruxBlackboxRelabel;
      }
      {
        job_name = "blackbox-tcp";
        metrics_path = "/probe";
        params = { module = [ "tcp_connect" ]; };
        static_configs = [{
          targets = tcpTargets;
          labels = { probe_location = "local"; };
        }];
        relabel_configs = mkBlackboxRelabel [
          {
            target_label = "probe_location";
            replacement = "local";
          }
        ];
      }
      {
        job_name = "wg-portal";
        scrape_interval = "60s";
        static_configs = [{ targets = [ "metrics.wg.prestonhager.com" ]; }];
      }
    ];
  };
}
