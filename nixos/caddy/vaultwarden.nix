{ config, ... }:

{
  services.caddy = {
    virtualHosts."vault.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:8081
    '';
  };
}

