# ai.prestonhager.com — OpenClaw gateway + optional Ollama API (K80 stack).
# LAN-only: Caddy @lan remote_ip matcher (RFC1918 + homelab 192.168.5.0/24).
# Zitadel SSO: Caddy → oauth2-proxy (reverse proxy) → OpenClaw trusted-proxy auth.
# oauth2-proxy must sit in front of OpenClaw (not forward_auth only) so WebSocket
# upgrades receive X-Forwarded-Email. /ollama keeps forward_auth (HTTP API only).
# See docs/ace-openclaw-sso.md

{ config, ... }:

let
  oauthProxy = "127.0.0.1:4181";

  oauthProxyHeaders = ''
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Host {host}
  '';

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

  oauthReverseProxy = ''
    reverse_proxy ${oauthProxy} {
      ${oauthProxyHeaders}
      flush_interval -1
      transport http {
        read_timeout 0
        write_timeout 0
      }
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
          ${oauthReverseProxy}
        }
      }

      handle {
        respond "Forbidden" 403
      }
    '';
  };
}
