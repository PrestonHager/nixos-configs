{ config, ... }:

{
  services.caddy = {
    virtualHosts."grafana.prestonhager.com".extraConfig = ''
      reverse_proxy http://127.0.0.1:8082
    '';
  };
}

