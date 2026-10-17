{ config, ... }:

{
  # Plain HTTP health endpoints for blackbox probes (no Host header / named vhost required).
  services.caddy.virtualHosts = {
    "http://127.0.0.1" = {
      extraConfig = ''
        bind 127.0.0.1
        respond / "ok" 200
      '';
    };
    "http://192.168.5.5" = {
      extraConfig = ''
        bind 192.168.5.5
        respond / "ok" 200
      '';
    };
  };
}
