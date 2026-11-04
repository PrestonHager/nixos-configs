{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  panelRoot = "/pterodactyl/html";
  panelPublicUrl = "https://panel.prestonhager.com";
  kc = import ../auth/keycloak-lib.nix;
  # homelab.keycloak.clients.pterodactyl (hydrodactyl.nix)
  ssoClientId = "pterodactyl";
  ssoCallbackPath = "/extensions/sociallogin/callback";
  ssoRedirectPath = "/extensions/sociallogin/redirect/keycloak";

  keycloakAdminSync = ./pterodactyl/KeycloakAdminSync.php;
  seedProviderPhp = ./pterodactyl/seed-sso-provider.php;
  ssoEnvFile = config.sops.secrets."pterodactyl-oauth-env".path;

  configureSsoScript = pkgs.writeShellScript "pterodactyl-sso-configure" ''
    set -euo pipefail
    panel="${panelRoot}"

    if [ ! -d "$panel/.blueprint" ]; then
      echo "pterodactyl-sso-configure: Blueprint not installed, skipping" >&2
      exit 0
    fi

    # shellcheck disable=SC1090
    source "${ssoEnvFile}"
    PTERODACTYL_OIDC_CLIENT_ID=${ssoClientId}
    if [ -z "''${PTERODACTYL_OIDC_CLIENT_SECRET:-}" ]; then
      echo "pterodactyl-sso-configure: missing OIDC credentials in pterodactyl-oauth-env" >&2
      exit 1
    fi
    if [ "$PTERODACTYL_OIDC_CLIENT_SECRET" = "REPLACE_ME" ]; then
      echo "pterodactyl-sso-configure: placeholder client secret, skipping" >&2
      exit 1
    fi

    echo "pterodactyl-sso-configure: configuring Keycloak OIDC via Blueprint Social Login..."

    ${pkgs.podman}/bin/podman exec \
      -e HOME=/var/www/pterodactyl \
      -e COMPOSER_HOME=/tmp/composer \
      pterodactyl \
      sh -c 'cd /var/www/pterodactyl && composer require socialiteproviders/manager socialiteproviders/keycloak --no-interaction --optimize-autoloader'

    install -m 0644 ${keycloakAdminSync} "$panel/app/Listeners/KeycloakAdminSync.php"
    chown pterodactyl:pterodactyl "$panel/app/Listeners/KeycloakAdminSync.php"
    rm -f "$panel/app/Listeners/ZitadelAdminSync.php"

    providers_file=$(find "$panel" -path '*/sociallogin/*SocialAuthController.php' 2>/dev/null | head -1)
    if [ -z "$providers_file" ]; then
      providers_file=$(find "$panel" -name 'SocialAuthController.php' 2>/dev/null | head -1)
    fi
    if [ -n "$providers_file" ] && grep -q -i zitadel "$providers_file"; then
      # Patched for Zitadel before the move to Keycloak: switch those patches.
      ${pkgs.python3}/bin/python3 - "$providers_file" "${kc.issuer}" "${kc.realm}" <<'PY'
import re, sys
path, issuer, realm = sys.argv[1:4]
text = open(path).read()
text = text.replace("'zitadel' => \\SocialiteProviders\\Zitadel\\Provider::class", "'keycloak' => \\SocialiteProviders\\Keycloak\\Provider::class")
text = re.sub(r"\n *'services\.zitadel\.project_id' => env\('ZITADEL_PROJECT_ID'\),", "", text)
text = re.sub(r"'services\.zitadel\.base_url' => env\('ZITADEL_BASE_URL', '[^']*'\),",
              "'services.keycloak.base_url' => env('KEYCLOAK_BASE_URL', 'https://keycloak.prestonhager.com'),\n                'services.keycloak.realms' => env('KEYCLOAK_REALM', '" + realm + "'),", text)
text = text.replace("short_name === 'zitadel'", "short_name === 'keycloak'")
text = text.replace("syncZitadelAdminRole", "syncSsoAdminRole").replace("zitadel_sso_groups", "sso_groups")
open(path, 'w').write(text)
PY
      chown pterodactyl:pterodactyl "$providers_file"
    fi
    if [ -n "$providers_file" ] && ! grep -q "SocialiteProviders\\\\Keycloak" "$providers_file"; then
      ${pkgs.gnused}/bin/sed -i "/'zoho'/i\\            'keycloak' => \\\\SocialiteProviders\\\\Keycloak\\\\Provider::class," "$providers_file"
      ${pkgs.python3}/bin/python3 - "$providers_file" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '        config([\n            f"services.{provider->short_name}.client_id"'
if 'services.keycloak.base_url' not in text and needle.replace('{provider->short_name}', '{provider.short_name}') in text.replace('->', '.'):
    needle = needle.replace('->', '.')
if 'services.keycloak.base_url' not in text:
    for n in [
        '        config([\n            f"services.{provider.short_name}.client_id"',
        '        config([\n            "services.{$provider->short_name}.client_id"',
    ]:
        if n in text:
            insert = '''        if ($provider->short_name === 'keycloak') {
            config([
                'services.keycloak.base_url' => env('KEYCLOAK_BASE_URL', 'https://keycloak.prestonhager.com'),
                'services.keycloak.realms' => env('KEYCLOAK_REALM', 'homelab'),
            ]);
        }

'''
            text = text.replace(n, insert + n, 1)
            break
if 'syncSsoAdminRole' not in text and 'auth()->login($user, true);' in text:
    text = text.replace(
        'auth()->login($user, true);',
        'auth()->login($user, true);\n        $this->syncSsoAdminRole($user, $socialUser);',
        1,
    )
    method = '''
    protected function syncSsoAdminRole($user, $socialUser): void
    {
        $raw = $socialUser->user ?? [];
        $groups = [];
        if (isset($raw['groups']) && is_array($raw['groups'])) {
            $groups = $raw['groups'];
        }
        session()->put('sso_groups', $groups);
        $isAdmin = in_array('pterodactyl_admin', $groups, true);
        if ($user->root_admin !== $isAdmin) {
            $user->root_admin = $isAdmin;
            $user->save();
        }
    }

'''
    text = text.replace("\n    /**\n     * Link a social account", method + "\n    /**\n     * Link a social account", 1)
open(path, 'w').write(text)
PY
      chown pterodactyl:pterodactyl "$providers_file"
    fi

    app_provider="$panel/app/Providers/AppServiceProvider.php"
    if [ -f "$app_provider" ] && grep -q ZitadelAdminSync "$app_provider"; then
      ${pkgs.gnused}/bin/sed -i 's/ZitadelAdminSync/KeycloakAdminSync/g' "$app_provider"
    fi
    if [ -f "$app_provider" ] && ! grep -q KeycloakAdminSync "$app_provider"; then
      if ! grep -q 'use Illuminate\\Support\\Facades\\Event;' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Illuminate\\Support\\Facades\\Event;' "$app_provider"
      fi
      if ! grep -q 'use Illuminate\\Auth\\Events\\Login;' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Illuminate\\Auth\\Events\\Login;' "$app_provider"
      fi
      if ! grep -q 'use Pterodactyl\\Listeners\\KeycloakAdminSync;' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Pterodactyl\\Listeners\\KeycloakAdminSync;' "$app_provider"
      fi
      ${pkgs.python3}/bin/python3 - "$app_provider" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'KeycloakAdminSync' not in text:
    text = text.replace(
        'public function boot(): void\n    {',
        'public function boot(): void\n    {\n        Event::listen(Login::class, KeycloakAdminSync::class);',
        1,
    )
    open(path, 'w').write(text)
PY
      chown pterodactyl:pterodactyl "$app_provider"
    fi

    services_file="$panel/config/services.php"
    if [ -f "$services_file" ] && grep -q "'zitadel' =>" "$services_file"; then
      ${pkgs.python3}/bin/python3 - "$services_file" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\n    'zitadel' => \[.*?\n    \],\n", "\n", text, count=1, flags=re.S)
open(path, 'w').write(text)
PY
    fi
    if [ -f "$services_file" ] && ! grep -q "'keycloak' =>" "$services_file"; then
      ${pkgs.python3}/bin/python3 - "$services_file" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
snippet = """
    'keycloak' => [
        'client_id' => env('KEYCLOAK_CLIENT_ID'),
        'client_secret' => env('KEYCLOAK_CLIENT_SECRET'),
        'redirect' => env('KEYCLOAK_REDIRECT_URI'),
        'base_url' => env('KEYCLOAK_BASE_URL', 'https://keycloak.prestonhager.com'),
        'realms' => env('KEYCLOAK_REALM', 'homelab'),
    ],
"""
open(path, 'w').write(text.replace("\n];", snippet + "\n];", 1))
PY
      chown pterodactyl:pterodactyl "$services_file"
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
    # Caddy reaches php-fpm over FastCGI and passes the client as
    # REMOTE_ADDR, so only local callers may set X-Forwarded-*; "*" let any
    # client spoof its IP and scheme.
    set_kv TRUSTED_PROXIES "127.0.0.1,::1,10.88.0.1"
    ${pkgs.gnused}/bin/sed -i '/^ZITADEL_/d' "$envFile"
    set_kv KEYCLOAK_CLIENT_ID "$PTERODACTYL_OIDC_CLIENT_ID"
    set_kv KEYCLOAK_CLIENT_SECRET "$PTERODACTYL_OIDC_CLIENT_SECRET"
    # socialiteproviders/keycloak builds <base_url>/realms/<realms>/...
    set_kv KEYCLOAK_BASE_URL "https://${kc.domain}"
    set_kv KEYCLOAK_REALM "${kc.realm}"
    set_kv KEYCLOAK_REDIRECT_URI "${panelPublicUrl}${ssoCallbackPath}"

    rm -f "$panel/.nix-seed-zitadel-provider.php"
    install -m 0644 ${seedProviderPhp} "$panel/.nix-seed-sso-provider.php"
    chown pterodactyl:pterodactyl "$panel/.nix-seed-sso-provider.php"
    ${pkgs.podman}/bin/podman exec \
      -e PTERODACTYL_OIDC_CLIENT_ID="$PTERODACTYL_OIDC_CLIENT_ID" \
      -e PTERODACTYL_OIDC_CLIENT_SECRET="$PTERODACTYL_OIDC_CLIENT_SECRET" \
      pterodactyl \
      php /var/www/pterodactyl/.nix-seed-sso-provider.php \
      || echo "pterodactyl-sso-configure: provider seed skipped (configure in admin if needed)" >&2

    ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
    ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan view:clear

    echo "pterodactyl-sso-configure: Keycloak SSO ready at ${panelPublicUrl}${ssoRedirectPath}"
  '';
in
{
  sops.secrets = {
    "pterodactyl-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl-oauth.yaml";
      key = "pterodactyl-oauth-env";
    };
  };

  systemd.services.pterodactyl-sso-configure = {
    description = "Configure Keycloak OIDC SSO via Blueprint Social Login on production panel";
    after = [
      "sops-nix.service"
      "pterodactyl-blueprint-install.service"
    ];
    wants = [
      "sops-nix.service"
      "pterodactyl-blueprint-install.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = configureSsoScript;
      RemainAfterExit = true;
      TimeoutStartSec = "30min";
    };
  };
}
