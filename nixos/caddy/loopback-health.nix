{ config, ... }:

{
  # Plain HTTP health endpoints for blackbox probes (no Host header / named vhost required).
  # No `bind`: binding 192.168.5.5 gave that address its own :80 server, which then
  # caught every request to ace's LAN IP (all port-forwarded internet traffic) and
  # answered unknown hosts with an empty 200 instead of the HTTP->HTTPS redirect.
  services.caddy.virtualHosts = {
    "http://127.0.0.1" = {
      extraConfig = ''
        respond / "ok" 200
      '';
    };
    "http://192.168.5.5" = {
      extraConfig = ''
        respond / "ok" 200
      '';
    };
  };
}
