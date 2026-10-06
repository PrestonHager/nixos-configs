{ config, pkgs, inputs, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
  panelRoot = "/pterodactyl/html";
  panelPublicUrl = "https://panel.prestonhager.com";
  zitadelIssuer = "https://zitadel.prestonhager.com";
  zitadelProjectId = "376196450586990901";
  ssoCallbackPath = "/extensions/sociallogin/callback";
  ssoRedirectPath = "/extensions/sociallogin/redirect/zitadel";

  zitadelAdminSync = ./pterodactyl/ZitadelAdminSync.php;
  seedProviderPhp = ./pterodactyl/seed-zitadel-provider.php;
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
    if [ -z "''${PTERODACTYL_OIDC_CLIENT_ID:-}" ] || [ -z "''${PTERODACTYL_OIDC_CLIENT_SECRET:-}" ]; then
      echo "pterodactyl-sso-configure: missing OIDC credentials in pterodactyl-oauth-env" >&2
      exit 1
    fi
    if [ "$PTERODACTYL_OIDC_CLIENT_ID" = "REPLACE_ZITADEL_CLIENT_ID" ]; then
      echo "pterodactyl-sso-configure: placeholder client id, skipping" >&2
      exit 1
    fi

    echo "pterodactyl-sso-configure: configuring Zitadel OIDC via Blueprint Social Login..."

    ${pkgs.podman}/bin/podman exec \
      -e HOME=/var/www/pterodactyl \
      -e COMPOSER_HOME=/tmp/composer \
      pterodactyl \
      sh -c 'cd /var/www/pterodactyl && composer require socialiteproviders/manager socialiteproviders/zitadel --no-interaction --optimize-autoloader'

    install -m 0644 ${zitadelAdminSync} "$panel/app/Listeners/ZitadelAdminSync.php"
    chown pterodactyl:pterodactyl "$panel/app/Listeners/ZitadelAdminSync.php"

    providers_file=$(find "$panel" -path '*/sociallogin/*SocialAuthController.php' 2>/dev/null | head -1)
    if [ -z "$providers_file" ]; then
      providers_file=$(find "$panel" -name 'SocialAuthController.php' 2>/dev/null | head -1)
    fi
    if [ -n "$providers_file" ] && ! grep -q "SocialiteProviders\\\\Zitadel" "$providers_file"; then
      ${pkgs.gnused}/bin/sed -i "/'zoho'/i\\            'zitadel' => \\\\SocialiteProviders\\\\Zitadel\\\\Provider::class," "$providers_file"
      ${pkgs.python3}/bin/python3 - "$providers_file" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = '        config([\n            f"services.{provider->short_name}.client_id"'
if 'services.zitadel.base_url' not in text and needle.replace('{provider->short_name}', '{provider.short_name}') in text.replace('->', '.'):
    needle = needle.replace('->', '.')
if 'services.zitadel.base_url' not in text:
    for n in [
        '        config([\n            f"services.{provider.short_name}.client_id"',
        '        config([\n            "services.{$provider->short_name}.client_id"',
    ]:
        if n in text:
            insert = '''        if ($provider->short_name === 'zitadel') {
            config([
                'services.zitadel.base_url' => env('ZITADEL_BASE_URL', 'https://zitadel.prestonhager.com'),
                'services.zitadel.project_id' => env('ZITADEL_PROJECT_ID'),
            ]);
        }

'''
            text = text.replace(n, insert + n, 1)
            break
if 'syncZitadelAdminRole' not in text and 'auth()->login($user, true);' in text:
    text = text.replace(
        'auth()->login($user, true);',
        'auth()->login($user, true);\n        $this->syncZitadelAdminRole($user, $socialUser);',
        1,
    )
    method = '''
    protected function syncZitadelAdminRole($user, $socialUser): void
    {
        $raw = $socialUser->user ?? [];
        $groups = [];
        if (isset($raw['groups']) && is_array($raw['groups'])) {
            $groups = $raw['groups'];
        }
        session()->put('zitadel_sso_groups', $groups);
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
    if [ -f "$app_provider" ] && ! grep -q ZitadelAdminSync "$app_provider"; then
      if ! grep -q 'use Illuminate\\Support\\Facades\\Event;' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Illuminate\\Support\\Facades\\Event;' "$app_provider"
      fi
      if ! grep -q 'use Illuminate\\Auth\\Events\\Login;' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Illuminate\\Auth\\Events\\Login;' "$app_provider"
      fi
      if ! grep -q 'use Pterodactyl\\Listeners\\ZitadelAdminSync;' "$app_provider"; then
        ${pkgs.gnused}/bin/sed -i '/^namespace Pterodactyl\\Providers;/a use Pterodactyl\\Listeners\\ZitadelAdminSync;' "$app_provider"
      fi
      ${pkgs.python3}/bin/python3 - "$app_provider" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'ZitadelAdminSync' not in text:
    text = text.replace(
        'public function boot(): void\n    {',
        'public function boot(): void\n    {\n        Event::listen(Login::class, ZitadelAdminSync::class);',
        1,
    )
    open(path, 'w').write(text)
PY
      chown pterodactyl:pterodactyl "$app_provider"
    fi

    services_file="$panel/config/services.php"
    if [ -f "$services_file" ] && ! grep -q "'zitadel'" "$services_file"; then
      ${pkgs.python3}/bin/python3 - "$services_file" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
snippet = """
    'zitadel' => [
        'client_id' => env('ZITADEL_CLIENT_ID'),
        'client_secret' => env('ZITADEL_CLIENT_SECRET'),
        'redirect' => env('ZITADEL_REDIRECT_URI'),
        'base_url' => env('ZITADEL_BASE_URL', 'https://zitadel.prestonhager.com'),
        'project_id' => env('ZITADEL_PROJECT_ID'),
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
    set_kv TRUSTED_PROXIES "*"
    set_kv ZITADEL_CLIENT_ID "$PTERODACTYL_OIDC_CLIENT_ID"
    set_kv ZITADEL_CLIENT_SECRET "$PTERODACTYL_OIDC_CLIENT_SECRET"
    set_kv ZITADEL_BASE_URL "${zitadelIssuer}"
    set_kv ZITADEL_PROJECT_ID "${zitadelProjectId}"
    set_kv ZITADEL_REDIRECT_URI "${panelPublicUrl}${ssoCallbackPath}"

    install -m 0644 ${seedProviderPhp} "$panel/.nix-seed-zitadel-provider.php"
    chown pterodactyl:pterodactyl "$panel/.nix-seed-zitadel-provider.php"
    ${pkgs.podman}/bin/podman exec \
      -e PTERODACTYL_OIDC_CLIENT_ID="$PTERODACTYL_OIDC_CLIENT_ID" \
      -e PTERODACTYL_OIDC_CLIENT_SECRET="$PTERODACTYL_OIDC_CLIENT_SECRET" \
      pterodactyl \
      php /var/www/pterodactyl/.nix-seed-zitadel-provider.php \
      || echo "pterodactyl-sso-configure: provider seed skipped (configure in admin if needed)" >&2

    ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
    ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan view:clear

    echo "pterodactyl-sso-configure: Zitadel SSO ready at ${panelPublicUrl}${ssoRedirectPath}"
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
    description = "Configure Zitadel OIDC SSO via Blueprint Social Login on production panel";
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
