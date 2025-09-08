{ config, ... }:

{
  services.caddy = {
    virtualHosts."zitadel.prestonhager.com".extraConfig = ''
      @allowedSubnet {
        remote_ip 192.168.8.0/24
      }

      handle @allowedSubnet {
        reverse_proxy http://localhost:9080
      }

      handle {
        respond "Forbidden" 403
      }
     '';
  };
}


