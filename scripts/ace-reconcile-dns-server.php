<?php

require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContextFactory;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;

$serverId = (int) ($argv[1] ?? 14);
$context = (new PluginContextFactory())->make();

echo "Reconciling DNS for server {$serverId}...\n";
Services::srvProvisioner($context)->provision($serverId);

$records = Services::state($context)->dnsRecords($serverId);
echo json_encode($records, JSON_PRETTY_PRINT) . "\n";
echo "done\n";
