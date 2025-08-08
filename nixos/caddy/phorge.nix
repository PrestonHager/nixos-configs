{ config, ... }:

{
  services.caddy = {
    virtualHosts."phorge.loftiawiki.org".extraConfig = ''
      @allowOnlyLocal {
        remote_ip 192.168.8.0/24
      }

      reverse_proxy @allowOnlyLocal http://localhost:8091
      respond "Forbidden" 403
    '';
    virtualHosts."phorge.loftiawiki.com".extraConfig = ''
      redir https://phorge.loftiawiki.org{uri} permanent
    '';
  };
}

