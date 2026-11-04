<?php
// Enables Coolify's "Sign in with Keycloak" (Coolify's generic OIDC provider,
// realm homelab) and retires the Zitadel provider. The client secret comes
// from the coolify-keycloak-env sops secret, passed with `podman exec
// --env-file`; the client itself is homelab.keycloak.clients.coolify.
use App\Models\OauthIdentity;
use App\Models\OauthSetting;

$secret = getenv('KEYCLOAK_CLIENT_SECRET');
if (! $secret) {
    throw new RuntimeException('KEYCLOAK_CLIENT_SECRET missing');
}

$setting = OauthSetting::firstOrNew(['provider' => 'oidc']);
$setting->fill([
    'client_id' => 'coolify',
    'client_secret' => $secret,
    'redirect_uri' => 'https://coolify.prestonhager.com/auth/oidc/callback',
    'base_url' => 'https://keycloak.prestonhager.com/realms/homelab',
    'custom_label' => 'Keycloak',
    'scopes' => 'openid email profile',
    'use_pkce' => true,
    'enabled' => true,
    // Keycloak lets every realm user through, so Coolify must not create
    // accounts on login. coolify-keycloak-roles creates them for members of
    // the coolify_admin / coolify_member groups; logins link by verified email.
    'allow_registration' => false,
    'auto_join_root_team' => false,
    'require_email_verified' => true,
]);
$setting->save();

// Zitadel is being retired. Coolify links at most one OAuth identity per
// account, so the old Zitadel identities must go for existing accounts to
// link their Keycloak login (by verified email). The accounts stay.
$zitadel = OauthSetting::firstWhere('provider', 'zitadel');
if ($zitadel?->enabled) {
    $zitadel->update(['enabled' => false]);
    echo 'zitadel oauth disabled' . PHP_EOL;
}
$dropped = OauthIdentity::where('provider', 'zitadel')->delete();
if ($dropped) {
    echo "dropped {$dropped} zitadel identity link(s)" . PHP_EOL;
}

echo 'keycloak oidc enabled=' . var_export($setting->couldBeEnabled() && $setting->enabled, true) . PHP_EOL;
