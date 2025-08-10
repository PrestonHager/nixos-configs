{ config, ... }:

{
  services.caddy = {
    virtualHosts."phorge.loftiawiki.org".extraConfig = ''
      @allowedSubnet {
        remote_ip 192.168.8.0/24
        remote_ip 10.88.0.0/16
      }

      handle @allowedSubnet {
        reverse_proxy http://localhost:8091
      }

      handle {
        respond "Forbidden" 403
      }
    '';
    virtualHosts."phorge.loftiawiki.com".extraConfig = ''
      redir https://phorge.loftiawiki.org{uri} permanent
    '';
  };
}

