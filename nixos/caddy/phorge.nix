{ config, ... }:

{
  services.caddy = {
    virtualHosts."phorge.loftiawiki.org".extraConfig = ''
      @allowOnlyLocal {
        remote_ip 192.168.8.0/24
      }

      reverse_proxy @allowOnlyLocal http://localhost:8091
      abort
    '';
    virtualHosts."phorge.loftiawiki.com".extraConfig = ''
      redir https://phorge.loftiawiki.org{uri} permanent
    '';
  };
}

