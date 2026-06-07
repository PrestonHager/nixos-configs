{ lib, ... }:
let
  sanitize = s: lib.replaceStrings [ "." ] [ "_" ] s;

  # HTTPS targets probed from crux using LAN DNS (LanCache @ 192.168.5.5).
  lanHttpHosts = [
    "grafana.prestonhager.com"
    "cloud.prestonhager.com"
    "zitadel.prestonhager.com"
    "dns.prestonhager.com"
    "matrix.prestonhager.com"
  ];

  lanDnsChecks = [
    {
      host = "grafana.prestonhager.com";
      expected = "192.168.5.5";
    }
  ];

  mkDnsModule = { host, expected }: {
    prober = "dns";
    timeout = "5s";
    dns = {
      transport_protocol = "udp";
      preferred_ip_protocol = "ip4";
      query_name = host;
      query_type = "A";
      valid_rcodes = [ "NOERROR" ];
      validate_answer_rrs.fail_if_not_matches_regexp.A = [ expected ];
    };
  };

  dnsModules = lib.listToAttrs (map (entry: {
    name = "dns_lan_${sanitize entry.host}";
    value = mkDnsModule entry;
  }) lanDnsChecks);
in {
  inherit lanHttpHosts lanDnsChecks;
  blackboxYml = lib.generators.toYAML { } {
    modules = {
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
    } // dnsModules;
  };
}
