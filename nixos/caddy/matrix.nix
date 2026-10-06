{ config, ... }:

{
  services.caddy = {
    virtualHosts."matrix.prestonhager.com".extraConfig = ''
      reverse_proxy http://localhost:6167 {
        header_up Host {host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
      }
    '';
  };
}


