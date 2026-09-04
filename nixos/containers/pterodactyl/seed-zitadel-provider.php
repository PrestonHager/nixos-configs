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

\Pterodactyl\Models\SocialProvider::updateOrCreate(
    ['short_name' => 'zitadel'],
    [
        'enabled' => true,
        'name' => 'Zitadel',
        'client_id' => $clientId,
        'client_secret' => Illuminate\Support\Facades\Crypt::encryptString($clientSecret),
    ]
);

echo "zitadel provider seeded\n";
