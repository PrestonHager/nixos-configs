{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  testPanelDir = "/home/prestonh/Projects/panel";
  testEnvFile = "/var/lib/pterodactyl-test/pterodactyl.env";
  panelPublicUrl = "https://test.panel.prestonhager.com";
  kc = import ../auth/keycloak-lib.nix;
  # homelab.keycloak.clients.pterodactyl (hydrodactyl.nix)
  ssoClientId = "pterodactyl";
  ssoCallbackPath = "/extensions/sociallogin/callback";
  ssoRedirectPath = "/extensions/sociallogin/redirect/keycloak";

  keycloakTestAdminSync = ./pterodactyl/KeycloakTestAdminSync.php;
  testAdminGroup = "pterodactyl_test_admin";
  seedProviderPhp = ./pterodactyl/seed-sso-provider.php;
  ssoEnvFile = config.sops.secrets."pterodactyl-oauth-env".path;

  configureSsoScript = pkgs.writeShellScript "pterodactyl-test-sso-configure" ''
    set -euo pipefail
    panel="${testPanelDir}"

    if [ ! -d "$panel/.blueprint" ]; then
      echo "pterodactyl-test-sso-configure: Blueprint not installed, skipping" >&2
      exit 0
    fi

    if [ ! -d "$panel/.blueprint/extensions/sociallogin" ]; then
      echo "pterodactyl-test-sso-configure: Social Login extension missing, skipping" >&2
      exit 1
    fi

    # shellcheck disable=SC1090
    source "${ssoEnvFile}"
    PTERODACTYL_OIDC_CLIENT_ID=${ssoClientId}
    if [ -z "''${PTERODACTYL_OIDC_CLIENT_SECRET:-}" ]; then
      echo "pterodactyl-test-sso-configure: missing OIDC credentials in pterodactyl-oauth-env" >&2
      exit 1
    fi
    if [ "$PTERODACTYL_OIDC_CLIENT_SECRET" = "REPLACE_ME" ]; then
      echo "pterodactyl-test-sso-configure: placeholder client secret, skipping" >&2
      exit 1
    fi

    echo "pterodactyl-test-sso-configure: configuring Keycloak OIDC via Blueprint Social Login..."

    private="$panel/.blueprint/extensions/blueprint/private"
    install -d -m 0755 -o prestonh -g users "$private/debug" "$private/db"
    if [ ! -f "$private/extensionfs.php" ] && [ -f "/pterodactyl/html/.blueprint/extensions/blueprint/private/extensionfs.php" ]; then
      echo "pterodactyl-test-sso-configure: restoring Blueprint extensionfs.php from production..."
      cp -a /pterodactyl/html/.blueprint/extensions/blueprint/private/extensionfs.php "$private/extensionfs.php"
      chown prestonh:users "$private/extensionfs.php"
    fi

    ${pkgs.podman}/bin/podman exec pterodactyl-test \
      php /var/www/pterodactyl/artisan migrate --force

    ${pkgs.podman}/bin/podman exec \
      -e HOME=/var/www/pterodactyl \
      -e COMPOSER_HOME=/tmp/composer \
      pterodactyl-test \
      sh -c 'cd /var/www/pterodactyl && composer require socialiteproviders/manager socialiteproviders/keycloak --no-interaction --optimize-autoloader'

    install -m 0644 ${keycloakTestAdminSync} "$panel/app/Listeners/KeycloakTestAdminSync.php"
    chown prestonh:users "$panel/app/Listeners/KeycloakTestAdminSync.php"
    rm -f "$panel/app/Listeners/ZitadelAdminSync.php" "$panel/app/Listeners/ZitadelTestAdminSync.php" \
      "$panel/app/Listeners/KeycloakAdminSync.php"

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
      chown prestonh:users "$providers_file"
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
            insert = (
                "        if ($provider->short_name === 'keycloak') {\n"
                "            config([\n"
                "                'services.keycloak.base_url' => env('KEYCLOAK_BASE_URL', 'https://keycloak.prestonhager.com'),\n"
                "                'services.keycloak.realms' => env('KEYCLOAK_REALM', 'homelab'),\n"
                "            ]);\n"
                "        }\n\n"
            )
            text = text.replace(n, insert + n, 1)
            break
open(path, 'w').write(text)
PY
      chown prestonh:users "$providers_file"
    fi

    if [ -n "$providers_file" ]; then
      ${pkgs.python3}/bin/python3 - "$providers_file" "${testAdminGroup}" <<'PY'
import sys
path, admin_group = sys.argv[1], sys.argv[2]
text = open(path).read()
if 'syncSsoAdminRole' not in text and 'auth()->login($user, true);' in text:
    text = text.replace(
        'auth()->login($user, true);',
        'auth()->login($user, true);\n        $this->syncSsoAdminRole($user, $socialUser);',
        1,
    )
    method = (
        "\n    protected function syncSsoAdminRole($user, $socialUser): void\n"
        "    {\n"
        "        $raw = $socialUser->user ?? [];\n"
        "        $groups = [];\n"
        "        if (isset($raw['groups']) && is_array($raw['groups'])) {\n"
        "            $groups = $raw['groups'];\n"
        "        }\n"
        "        session()->put('sso_groups', $groups);\n"
        f"        $isAdmin = in_array('{admin_group}', $groups, true);\n"
        "        if ($user->root_admin !== $isAdmin) {\n"
        "            $user->root_admin = $isAdmin;\n"
        "            $user->save();\n"
        "        }\n"
        "    }\n\n"
    )
    text = text.replace("\n    /**\n     * Link a social account", method + "\n    /**\n     * Link a social account", 1)
elif 'syncSsoAdminRole' in text:
    import re
    text = re.sub(
        r"in_array\('pterodactyl_admin'",
        f"in_array('{admin_group}'",
        text,
    )
open(path, 'w').write(text)
PY
      chown prestonh:users "$providers_file"
    fi

    app_provider="$panel/app/Providers/AppServiceProvider.php"
    if [ -f "$app_provider" ]; then
      if grep -q -E 'ZitadelTestAdminSync|ZitadelAdminSync|KeycloakAdminSync' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i -e 's/ZitadelTestAdminSync/KeycloakTestAdminSync/g' \
          -e 's/ZitadelAdminSync/KeycloakTestAdminSync/g' -e 's/\bKeycloakAdminSync/KeycloakTestAdminSync/g' "$app_provider"
      fi
      if ! grep -q 'Event::listen(Login::class, KeycloakTestAdminSync::class)' "$app_provider"; then
        if ! grep -q 'use Illuminate\\Support\\Facades\\Event;' "$app_provider"; then
          ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Illuminate\\Support\\Facades\\Event;' "$app_provider"
        fi
        if ! grep -q 'use Illuminate\\Auth\\Events\\Login;' "$app_provider"; then
          ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Illuminate\\Auth\\Events\\Login;' "$app_provider"
        fi
        if ! grep -q 'use Pterodactyl\\Listeners\\KeycloakTestAdminSync;' "$app_provider"; then
          ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Pterodactyl\\Listeners\\KeycloakTestAdminSync;' "$app_provider"
        fi
        ${pkgs.python3}/bin/python3 - "$app_provider" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'Event::listen(Login::class, KeycloakTestAdminSync::class)' not in text:
    text = text.replace(
        'public function boot(): void\n    {',
        'public function boot(): void\n    {\n        Event::listen(Login::class, KeycloakTestAdminSync::class);',
        1,
    )
    open(path, 'w').write(text)
PY
        chown prestonh:users "$app_provider"
      fi
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
      chown prestonh:users "$services_file"
    fi

    envFile="${testEnvFile}"
    touch "$envFile"
    chown pterodactyl:pterodactyl "$envFile"
    chmod 0640 "$envFile"
    set_kv() {
      local key="$1" val="$2"
      if grep -q "^''${key}=" "$envFile"; then
        ${pkgs.gnused}/bin/sed -i "s|^''${key}=.*|''${key}=$(printf '%s' "$val" | ${pkgs.gnused}/bin/sed 's/[&/\\|]/\\&/g')|" "$envFile"
      else
        printf '%s=%s\n' "$key" "$val" >> "$envFile"
      fi
    }
    set_kv APP_URL "${panelPublicUrl}"
    # Same values pterodactyl-test-env enforces (see pterodactyl-test.nix).
    set_kv TRUSTED_PROXIES "127.0.0.1,::1,10.88.0.1"
    set_kv SESSION_DOMAIN "test.panel.prestonhager.com"
    set_kv SESSION_COOKIE "pterodactyl_test_session"
    set_kv SESSION_SECURE_COOKIE "true"
    set_kv SESSION_SAME_SITE "lax"
    ${pkgs.gnused}/bin/sed -i '/^ZITADEL_/d' "$envFile"
    set_kv KEYCLOAK_CLIENT_ID "$PTERODACTYL_OIDC_CLIENT_ID"
    set_kv KEYCLOAK_CLIENT_SECRET "$PTERODACTYL_OIDC_CLIENT_SECRET"
    # socialiteproviders/keycloak builds <base_url>/realms/<realms>/...
    set_kv KEYCLOAK_BASE_URL "https://${kc.domain}"
    set_kv KEYCLOAK_REALM "${kc.realm}"
    set_kv KEYCLOAK_REDIRECT_URI "${panelPublicUrl}${ssoCallbackPath}"

    rm -f "$panel/.nix-seed-zitadel-provider.php"
    install -m 0644 ${seedProviderPhp} "$panel/.nix-seed-sso-provider.php"
    chown prestonh:users "$panel/.nix-seed-sso-provider.php"
    ${pkgs.podman}/bin/podman exec \
      -e PTERODACTYL_OIDC_CLIENT_ID="$PTERODACTYL_OIDC_CLIENT_ID" \
      -e PTERODACTYL_OIDC_CLIENT_SECRET="$PTERODACTYL_OIDC_CLIENT_SECRET" \
      pterodactyl-test \
      php /var/www/pterodactyl/.nix-seed-sso-provider.php \
      || echo "pterodactyl-test-sso-configure: provider seed skipped (configure in admin if needed)" >&2

    ${pkgs.podman}/bin/podman exec pterodactyl-test php /var/www/pterodactyl/artisan config:clear
    ${pkgs.podman}/bin/podman exec pterodactyl-test php /var/www/pterodactyl/artisan view:clear
    ${pkgs.podman}/bin/podman exec pterodactyl-test php /var/www/pterodactyl/artisan cache:clear

    echo "pterodactyl-test-sso-configure: Keycloak SSO ready at ${panelPublicUrl}${ssoRedirectPath}"
  '';
in
{
  sops.secrets = {
    "pterodactyl-oauth-env" = {
      sopsFile = "${sops-path}/secrets/containers/pterodactyl-oauth.yaml";
      key = "pterodactyl-oauth-env";
    };
  };

  systemd.services.pterodactyl-test-sso-configure = {
    description = "Configure Keycloak OIDC SSO via Blueprint Social Login on test panel";
    after = [
      "sops-nix.service"
      "pterodactyl-test-blueprint-install.service"
      "podman-pterodactyl-test.service"
    ];
    wants = [
      "sops-nix.service"
      "pterodactyl-test-blueprint-install.service"
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
