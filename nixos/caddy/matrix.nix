{ config, ... }:

{
  services.caddy = {
    virtualHosts."matrix.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:6167
    '';
  };
}


