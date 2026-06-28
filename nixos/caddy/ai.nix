# ai.prestonhager.com — OpenClaw gateway + optional Ollama API (K80 stack).
# LAN-only: Caddy @lan remote_ip matcher (RFC1918 + homelab 192.168.5.0/24).
# Zitadel SSO: oauth2-proxy forward_auth → OpenClaw trusted-proxy auth.
# See docs/ace-openclaw-sso.md

{ config, ... }:

let
  oauthProxy = "127.0.0.1:4181";

  oauthForwardAuth = ''
    forward_auth ${oauthProxy} {
      uri /oauth2/auth
      header_up X-Real-IP {remote_host}
      header_up X-Forwarded-Proto {scheme}
      header_up X-Forwarded-Host {host}
      copy_headers {
        X-Auth-Request-Email > X-Auth-Request-Email
      }
      @unauth status 401
      handle_response @unauth {
        redir * /oauth2/start?rd={http.request.orig_uri.path} 302
      }
    }
  '';

  openclawUpstream = ''
    reverse_proxy http://127.0.0.1:18789 {
      header_up Host {host}
      header_up X-Forwarded-Proto {scheme}
      header_up X-Forwarded-Host {host}
      header_up Connection {>Connection}
      header_up Upgrade {>Upgrade}
    }
  '';
in
{
  services.caddy = {
    virtualHosts."ai.prestonhager.com".extraConfig = ''
      @lan {
        remote_ip 192.168.5.0/24 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12
      }

      handle @lan {
        handle /oauth2/* {
          reverse_proxy ${oauthProxy} {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-Uri {uri}
          }
        }

        handle /ollama/* {
          ${oauthForwardAuth}
          uri strip_prefix /ollama
          reverse_proxy http://127.0.0.1:11434 {
            header_up Host {host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-Host {host}
          }
        }

        handle {
          ${oauthForwardAuth}
          ${openclawUpstream}
        }
      }

      handle {
        respond "Forbidden" 403
      }
    '';
  };
}
