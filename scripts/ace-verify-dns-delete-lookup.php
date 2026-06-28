<?php
require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;

$serverId = (int) ($argv[1] ?? 14);
$context = PluginContext::make();
$state = Services::state($context);

foreach ($state->dnsRecords($serverId) as $record) {
    $id = $state->recordKey($record);
    $found = $state->findRecord($serverId, $id);
    echo ($found ? 'OK' : 'MISSING') . " findRecord {$id} ({$record['type']} {$record['name']})\n";
}
