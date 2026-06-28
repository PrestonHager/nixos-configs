{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  zitadelIssuer = "https://zitadel.prestonhager.com";
  zitadelProjectId = "376196450586990901";
  aiPublicUrl = "https://ai.prestonhager.com";
  aiDomain = "ai.prestonhager.com";
  oauthRedirectUri = "${aiPublicUrl}/oauth2/callback";
  oauthProxyListen = "127.0.0.1:4181";

  oauthEnvFile = config.sops.secrets."openclaw-oauth-env".path;

  oauth2ProxyScript = pkgs.writeShellScript "openclaw-oauth2-proxy" ''
    set -euo pipefail
    # shellcheck disable=SC1090
    source "${oauthEnvFile}"
    if [ -z "''${OPENCLAW_OIDC_CLIENT_ID:-}" ] || [ -z "''${OPENCLAW_OIDC_CLIENT_SECRET:-}" ] || [ -z "''${OAUTH2_PROXY_COOKIE_SECRET:-}" ]; then
      echo "openclaw-oauth2-proxy: missing OIDC credentials in openclaw-oauth-env" >&2
      exit 1
    fi
    if [ "$OPENCLAW_OIDC_CLIENT_ID" = "REPLACE_ZITADEL_CLIENT_ID" ]; then
      echo "openclaw-oauth2-proxy: placeholder client id, skipping" >&2
      exit 1
    fi
    exec ${pkgs.oauth2-proxy}/bin/oauth2-proxy \
      --provider=oidc \
      --oidc-issuer-url=${zitadelIssuer} \
      --client-id="$OPENCLAW_OIDC_CLIENT_ID" \
      --client-secret="$OPENCLAW_OIDC_CLIENT_SECRET" \
      --redirect-url=${oauthRedirectUri} \
      --upstream=file:///dev/null \
      --http-address=${oauthProxyListen} \
      --cookie-secret="$OAUTH2_PROXY_COOKIE_SECRET" \
      --email-domain=* \
      --cookie-secure=true \
      --set-xauthrequest=true \
      --pass-user-headers=false \
      --user-id-claim=email \
      --whitelist-domain=${aiDomain} \
      --provider-display-name=Zitadel \
      --scope="openid profile email urn:zitadel:iam:org:project:id:${zitadelProjectId}:aud" \
      --reverse-proxy=true \
      --skip-auth-route=GET=^/oauth2/start$ \
      --skip-auth-route=GET=^/oauth2/sign_in$ \
      --skip-auth-route=GET=^/oauth2/static/.*$
  '';
in
{
  sops.secrets = {
    "openclaw-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/openclaw-oauth.yaml";
      key = "openclaw-oauth-env";
    };
  };

  systemd.services.openclaw-oauth2-proxy = {
    description = "oauth2-proxy for OpenClaw AI portal Zitadel SSO";
    after = [
      "network-online.target"
      "sops-nix.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = oauth2ProxyScript;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
