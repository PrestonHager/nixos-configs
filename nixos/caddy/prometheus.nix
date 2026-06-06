{ config, ... }:

{
  services.caddy = {
    virtualHosts."prometheus.prestonhager.com".extraConfig = ''
      @allowedSubnet {
        remote_ip 192.168.8.0/24
        remote_ip 10.88.0.0/16
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

