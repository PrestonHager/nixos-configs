{ config, docsSite, ... }:

{
  services.caddy.virtualHosts."serverdocs.prestonhager.com".extraConfig = ''
    @lan {
      remote_ip 192.168.5.0/24 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12
    }

    handle @lan {
      root * ${docsSite}
      try_files {path} {path}/ /index.html
      file_server
    }

    handle {
      respond "Forbidden" 403
    }
  '';
}
