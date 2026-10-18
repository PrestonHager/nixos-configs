{ config, ... }:

{
  services.caddy = {
    virtualHosts."prometheus.prestonhager.com".extraConfig = ''
      @allowedSubnet {
        remote_ip 192.168.5.0/24
      }

      handle @allowedSubnet {
        reverse_proxy http://localhost:9090
      }

      handle {
        respond "Forbidden" 403
      }
    '';
  };
}

