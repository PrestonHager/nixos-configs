{ config, ... }:

{
  services.caddy.virtualHosts."update.prestonhager.com" = {
    extraConfig = ''
      reverse_proxy 127.0.0.1:8765
    '';
  };
}
