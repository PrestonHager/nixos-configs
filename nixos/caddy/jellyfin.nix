{ config, ... }:

{
  services.caddy = {
    virtualHosts."jellyfin.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:8096
    '';
  };
}

