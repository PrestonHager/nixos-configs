{ lib, ... }:
let
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
    # Wings API returns 401 without a panel token — that is healthy.
    http_wings = {
      prober = "http";
      timeout = "15s";
      http = {
        valid_status_codes = [ 200 401 403 ];
        preferred_ip_protocol = "ip4";
        tls_config.insecure_skip_verify = false;
      };
    };
    tcp_connect = {
      prober = "tcp";
      timeout = "5s";
    };
  };
in {
  blackboxYml = lib.generators.toYAML { } {
    modules = baseModules;
  };
}
