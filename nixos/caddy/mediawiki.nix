{ config, ... }:

{
  services.caddy = {
    virtualHosts."loftiawiki.org".extraConfig = ''
      reverse_proxy http://localhost:8090
    '';
    virtualHosts."loftiawiki.com".extraConfig = ''
      redir https://loftiawiki.org{uri} permanent
    '';
  };
}

