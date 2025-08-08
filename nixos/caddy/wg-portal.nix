{ config, ... }:

{
  services.caddy = {
    virtualHosts."wg.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:8080
    '';
  };
}

