{ config, pkgs, ... }:

let
  nextcloudWellKnown = pkgs.runCommand "nextcloud-well-known" { } ''
    mkdir -p $out/.well-known
    cp ${../../static/nextcloud/.well-known/microsoft-identity-association.json} \
      $out/.well-known/microsoft-identity-association.json
  '';
in
{
  services.caddy = {
    virtualHosts."cloud.prestonhager.com".extraConfig = ''
      request_body {
        max_size 0
      }

      redir /.well-known/carddav /remote.php/dav 301
      redir /.well-known/caldav /remote.php/dav 301

      handle /.well-known/microsoft-identity-association.json {
        root * ${nextcloudWellKnown}
        header Content-Type application/json
        file_server
      }

      header Strict-Transport-Security "max-age=15552000; includeSubDomains"

      handle_path /push/* {
        reverse_proxy http://127.0.0.1:7867 {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      }

      handle_path /whiteboard/* {
        request_body {
          max_size 100MB
        }

        reverse_proxy http://127.0.0.1:3002 {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      }

      reverse_proxy http://127.0.0.1:8083 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        flush_interval -1
        transport http {
          read_timeout 1h
          write_timeout 1h
        }
      }
    '';
  };
}