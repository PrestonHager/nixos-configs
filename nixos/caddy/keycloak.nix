{ config, ... }:

let
  caddyLib = import ./lib.nix;
  kc = import ../auth/keycloak-lib.nix;

  # App containers on ace talk to Keycloak server-to-server (discovery, code
  # exchange, signing keys, userinfo). Caddy sees their bridge address, which
  # lanRanges deliberately excludes, so allow these bridges for exactly the
  # endpoints an IdP publishes to its clients anyway: the token endpoint wants
  # client credentials and userinfo a bearer token. Login pages and the admin
  # API stay LAN/tailnet/VPN only.
  #
  # The ghrunner bridge (10.250.250.0/24) is NOT here: it runs untrusted CI code.
  appBridges = [
    "10.88.0.0/16" # podman default network
    "10.89.0.0/24" # coolify network
  ];
  oidc = "/realms/${kc.realm}/protocol/openid-connect";
  backchannelPaths = [
    "/realms/${kc.realm}/.well-known/openid-configuration"
    "${oidc}/token"
    "${oidc}/token/introspect"
    # Pushed authorization requests (RFC 9126): advertised in discovery, so
    # ASP.NET's OIDC handler (Technitium) always uses it. Client-authenticated
    # like the token endpoint.
    "${oidc}/ext/par/request"
    "${oidc}/certs"
    "${oidc}/userinfo"
  ];
in
{
  # LAN/tailnet/VPN only, plus the back-channel carve-out above. No
  # Cloudflare record.
  services.caddy.virtualHosts.${kc.domain}.extraConfig = ''
    ${caddyLib.securityHeaders}

    @app_backchannel {
      remote_ip ${builtins.concatStringsSep " " appBridges}
      path ${builtins.concatStringsSep " " backchannelPaths}
    }
    handle @app_backchannel {
      reverse_proxy http://127.0.0.1:9280
    }

    ${caddyLib.lanOnly ''
      reverse_proxy http://127.0.0.1:9280
    ''}
  '';
}
