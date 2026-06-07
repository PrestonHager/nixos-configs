{ lib, ... }:
let
  sanitize = s: lib.replaceStrings [ "." ] [ "_" ] s;

  lanHosts = [
    "panel.prestonhager.com"
    "test.panel.prestonhager.com"
    "grafana.prestonhager.com"
    "jellyfin.prestonhager.com"
    "vault.prestonhager.com"
    "wg.prestonhager.com"
    "prometheus.prestonhager.com"
    "matrix.prestonhager.com"
    "zitadel.prestonhager.com"
    "cloud.prestonhager.com"
    "dns.prestonhager.com"
    "loftiawiki.org"
    "upgrade.loftiawiki.org"
  ];

  mkLanModule = host: {
    prober = "http";
    timeout = "15s";
    http = {
      valid_status_codes = [ 200 301 302 403 ];
      preferred_ip_protocol = "ip4";
      headers = { Host = host; };
      tls_config = { server_name = host; };
    };
  };

  baseModules = {
    http_2xx = {
      prober = "http";
      timeout = "15s";
      http = {
        valid_status_codes = [ 200 301 302 403 ];
        preferred_ip_protocol = "ip4";
        tls_config.insecure_skip_verify = false;
      };
    };
    http_local = {
      prober = "http";
      timeout = "10s";
      http = {
        valid_status_codes = [ 200 301 302 403 404 ];
        preferred_ip_protocol = "ip4";
      };
    };
    tcp_connect = {
      prober = "tcp";
      timeout = "5s";
    };
  };

  lanModules = lib.listToAttrs (map (host: {
    name = "http_lan_${sanitize host}";
    value = mkLanModule host;
  }) lanHosts);

  lanProbeEntries = map (host: {
    module = "http_lan_${sanitize host}";
    host = host;
  }) lanHosts;
in {
  inherit lanHosts lanProbeEntries;
  blackboxYml = lib.generators.toYAML { } {
    modules = baseModules // lanModules;
  };
}
