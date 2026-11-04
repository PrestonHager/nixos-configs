<?php

$root = '/var/www/pterodactyl';
require "$root/vendor/autoload.php";
$app = require "$root/bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$clientId = getenv('PTERODACTYL_OIDC_CLIENT_ID') ?: '';
$clientSecret = getenv('PTERODACTYL_OIDC_CLIENT_SECRET') ?: '';

if ($clientId === '' || $clientSecret === '') {
    fwrite(STDERR, "missing PTERODACTYL_OIDC_CLIENT_ID/SECRET\n");
    exit(1);
}

$bp = app(\Pterodactyl\BlueprintFramework\Libraries\ExtensionLibrary\Admin\BlueprintAdminLibrary::class);
$bp->dbSet('sociallogin', 'allow_register', '1');
$bp->dbSet('sociallogin', 'allow_connecting', '1');

// Rename a Zitadel row from before the move to Keycloak, so existing social
// links keep their provider id.
\Pterodactyl\Models\SocialProvider::where('short_name', 'zitadel')
    ->update(['short_name' => 'keycloak', 'name' => 'Keycloak']);

\Pterodactyl\Models\SocialProvider::updateOrCreate(
    ['short_name' => 'keycloak'],
    [
        'enabled' => true,
        'name' => 'Keycloak',
        'client_id' => $clientId,
        'client_secret' => Illuminate\Support\Facades\Crypt::encryptString($clientSecret),
    ]
);

echo "keycloak provider seeded\n";
