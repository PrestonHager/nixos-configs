{ config, ... }:

{
  services.caddy = {
    virtualHosts."git.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:8080
    '';
  };
}

