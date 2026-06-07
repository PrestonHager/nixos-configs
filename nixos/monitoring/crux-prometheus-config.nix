{ lib, ... }:
let
  aceIp = "192.168.5.5";
  cruxBlackboxCfg = import ./crux-blackbox-config.nix { inherit lib; };

  lanHttpsTargets = map (host: "https://${host}/") cruxBlackboxCfg.lanHttpHosts;

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
      replacement = "127.0.0.1:9115";
    }
  ] ++ extra;

  mkDnsRelabel = [
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
      replacement = "127.0.0.1:9115";
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
      targets = [ "http://${aceIp}/" ];
      labels = {
        __param_module = "http_local";
        probe_location = "lan";
        probe_source = "crux";
      };
    }
  ];

  lanDnsStaticConfigs = map (entry: {
    targets = [ aceIp ];
    labels = {
      __param_module = entry.module;
      instance = "dns://${aceIp}/${entry.host}";
      probe_location = "lan";
      probe_source = "crux";
      vhost = entry.host;
    };
  }) cruxBlackboxCfg.lanDnsChecks;

  lanTcpStaticConfigs = map (entry: {
    targets = [ entry.target ];
    labels = {
      __param_module = "tcp_connect";
      instance = entry.target;
      host = entry.host;
      probe_location = "lan";
      probe_source = "crux";
    };
  }) cruxBlackboxCfg.lanTcpTargets;

in {
  scrapeConfigs = [
    {
      job_name = "prometheus";
      static_configs = [{ targets = [ "localhost:9090" ]; }];
    }
    {
      job_name = "node";
      static_configs = [{
        targets = [ "localhost:9100" ];
        labels = { host = "crux"; };
      }];
    }
    {
      job_name = "blackbox-http-lan";
      metrics_path = "/probe";
      static_configs = lanHttpStaticConfigs;
      relabel_configs = mkBlackboxRelabel [
        {
          target_label = "probe_location";
          replacement = "lan";
        }
        {
          target_label = "probe_source";
          replacement = "crux";
        }
      ];
    }
    {
      job_name = "blackbox-dns-lan";
      metrics_path = "/probe";
      static_configs = lanDnsStaticConfigs;
      relabel_configs = mkDnsRelabel;
    }
    {
      job_name = "blackbox-tcp-lan";
      metrics_path = "/probe";
      static_configs = lanTcpStaticConfigs;
      relabel_configs = mkBlackboxRelabel [
        {
          target_label = "probe_location";
          replacement = "lan";
        }
        {
          target_label = "probe_source";
          replacement = "crux";
        }
      ];
    }
  ];
}
