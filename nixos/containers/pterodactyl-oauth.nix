{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  panelRoot = "/pterodactyl/html";
  zitadelIssuer = "https://zitadel.prestonhager.com";
  zitadelProjectId = "376196450586990901";
  panelPublicUrl = "https://panel.prestonhager.com";
  panelDomain = "panel.prestonhager.com";
  oauthRedirectUri = "${panelPublicUrl}/oauth2/callback";
  oauthProxyListen = "127.0.0.1:4180";
  adminRoleKey = "pterodactyl_admin";

  headerAuthMiddleware = ./pterodactyl/HeaderAuthentication.php;

  patchHeaderAuthScript = pkgs.writeShellScript "pterodactyl-patch-header-auth" ''
    set -euo pipefail
    panel="${panelRoot}"
    middleware="$panel/app/Http/Middleware/HeaderAuthentication.php"
    kernel="$panel/app/Http/Kernel.php"
    authCfg="$panel/config/auth.php"

    if [ ! -d "$panel/app" ]; then
      echo "pterodactyl-patch-header-auth: panel not installed at $panel, skipping" >&2
      exit 0
    fi

    install -m 0644 ${headerAuthMiddleware} "$middleware"
    chown pterodactyl:pterodactyl "$middleware"

    if ! grep -q HeaderAuthentication "$kernel"; then
      ${pkgs.gnused}/bin/sed -i '/LanguageMiddleware::class,/a\            \\Pterodactyl\\Http\\Middleware\\HeaderAuthentication::class,' "$kernel"
    fi

    if ! grep -q "'header' =>" "$authCfg"; then
      ${pkgs.python3}/bin/python3 - "$authCfg" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
snippet = """
    'header' => [
        'enabled' => env('AUTH_HEADER_ENABLED', false),
        'auto_create' => env('AUTH_HEADER_AUTO_CREATE', false),
        'username_header' => env('AUTH_HEADER_USERNAME', 'X-Auth-Username'),
        'email_header' => env('AUTH_HEADER_EMAIL', 'X-Auth-Email'),
        'groups_header' => env('AUTH_HEADER_GROUPS', 'X-Auth-Groups'),
        'admin_group' => env('AUTH_HEADER_ADMIN_GROUP', 'pterodactyl_admin'),
    ],
"""
open(path, 'w').write(text.replace("\n];", snippet + "\n];", 1))
PY
    fi

    envFile="$panel/.env"
    touch "$envFile"
    chown pterodactyl:pterodactyl "$envFile"
    set_kv() {
      local key="$1" val="$2"
      if grep -q "^''${key}=" "$envFile"; then
        ${pkgs.gnused}/bin/sed -i "s|^''${key}=.*|''${key}=$(printf '%s' "$val" | ${pkgs.gnused}/bin/sed 's/[&/\\|]/\\&/g')|" "$envFile"
      else
        printf '%s=%s\n' "$key" "$val" >> "$envFile"
      fi
    }
    set_kv APP_URL "${panelPublicUrl}"
    set_kv TRUSTED_PROXIES "*"
    set_kv AUTH_HEADER_ENABLED "true"
    set_kv AUTH_HEADER_AUTO_CREATE "true"
    set_kv AUTH_HEADER_USERNAME "X-Auth-Username"
    set_kv AUTH_HEADER_EMAIL "X-Auth-Email"
    set_kv AUTH_HEADER_GROUPS "X-Auth-Groups"
    set_kv AUTH_HEADER_ADMIN_GROUP "${adminRoleKey}"

    echo "pterodactyl-patch-header-auth: applied header auth middleware and .env SSO settings"
  '';

  oauthEnvFile = config.sops.secrets."pterodactyl-oauth-env".path;

  oauth2ProxyScript = pkgs.writeShellScript "pterodactyl-oauth2-proxy" ''
    set -euo pipefail
    # shellcheck disable=SC1090
    source "${oauthEnvFile}"
    if [ -z "''${PTERODACTYL_OIDC_CLIENT_ID:-}" ] || [ -z "''${PTERODACTYL_OIDC_CLIENT_SECRET:-}" ] || [ -z "''${OAUTH2_PROXY_COOKIE_SECRET:-}" ]; then
      echo "pterodactyl-oauth2-proxy: missing OIDC credentials in pterodactyl-oauth-env" >&2
      exit 1
    fi
    if [ "$PTERODACTYL_OIDC_CLIENT_ID" = "REPLACE_ZITADEL_CLIENT_ID" ]; then
      echo "pterodactyl-oauth2-proxy: placeholder client id, skipping" >&2
      exit 1
    fi
    exec ${pkgs.oauth2-proxy}/bin/oauth2-proxy \
      --provider=oidc \
      --oidc-issuer-url=${zitadelIssuer} \
      --client-id="$PTERODACTYL_OIDC_CLIENT_ID" \
      --client-secret="$PTERODACTYL_OIDC_CLIENT_SECRET" \
      --redirect-url=${oauthRedirectUri} \
      --upstream=file:///dev/null \
      --http-address=${oauthProxyListen} \
      --cookie-secret="$OAUTH2_PROXY_COOKIE_SECRET" \
      --email-domain=* \
      --cookie-secure=true \
      --set-xauthrequest=true \
      --pass-user-headers=false \
      --user-id-claim=preferred_username \
      --whitelist-domain=${panelDomain} \
      --provider-display-name=Zitadel \
      --scope="openid profile email urn:zitadel:iam:org:project:roles urn:zitadel:iam:org:project:id:${zitadelProjectId}:aud" \
      --oidc-groups-claim=groups \
      --reverse-proxy=true \
      --skip-auth-route=GET=^/oauth2/start$ \
      --skip-auth-route=GET=^/oauth2/sign_in$ \
      --skip-auth-route=GET=^/oauth2/static/.*$
  '';
in
{
  sops.secrets = {
    "pterodactyl-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl-oauth.yaml";
      key = "pterodactyl-oauth-env";
    };
  };

  systemd.services.pterodactyl-patch-header-auth = {
    description = "Apply Pterodactyl header-auth SSO middleware";
    after = [ "podman-pterodactyl.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = patchHeaderAuthScript;
      RemainAfterExit = true;
    };
  };

  systemd.services.pterodactyl-oauth2-proxy = {
    description = "oauth2-proxy for Pterodactyl panel Zitadel SSO";
    after = [
      "network-online.target"
      "sops-nix.service"
      "pterodactyl-patch-header-auth.service"
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
