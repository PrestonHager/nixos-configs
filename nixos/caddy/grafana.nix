{ config, ... }:

{
  services.caddy = {
    virtualHosts."grafana.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:8080
    '';
  };
}

