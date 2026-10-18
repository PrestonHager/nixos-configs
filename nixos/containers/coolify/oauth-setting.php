<?php
// Enables Coolify's Zitadel login. Client credentials come from the
// coolify-zitadel-env sops secret, passed with `podman exec --env-file`.
use App\Models\OauthSetting;

$id = getenv('ZITADEL_CLIENT_ID');
$secret = getenv('ZITADEL_CLIENT_SECRET');
if (! $id || ! $secret) {
    throw new RuntimeException('ZITADEL_CLIENT_ID / ZITADEL_CLIENT_SECRET missing');
}

$setting = OauthSetting::firstOrNew(['provider' => 'zitadel']);
$setting->fill([
    'client_id' => $id,
    'client_secret' => $secret,
    'redirect_uri' => 'https://coolify.prestonhager.com/auth/zitadel/callback',
    'base_url' => 'https://zitadel.prestonhager.com',
    'custom_label' => 'Zitadel',
    'enabled' => true,
    // Zitadel's Coolify project only lets users with a coolify_* role sign in,
    // so new accounts are gated there. Roles are applied by the sync timer.
    'allow_registration' => true,
    'auto_join_root_team' => false,
    'require_email_verified' => true,
]);
$setting->save();
echo 'zitadel oauth enabled=' . var_export($setting->couldBeEnabled() && $setting->enabled, true) . PHP_EOL;

