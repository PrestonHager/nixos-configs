<?php
require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

use Illuminate\Http\Request;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\SrvProfilesController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;

$serverId = (int) ($argv[1] ?? 14);
$admin = \Pterodactyl\Models\User::query()->where('root_admin', true)->first();

$pluginRequest = new PluginHttpRequest(
    request: Request::create("/extensions/dnsrecords/admin/servers/{$serverId}/srv-profiles", 'GET'),
    userId: $admin?->id,
    serverId: $serverId,
    body: [],
    query: [],
    route: ['server' => $serverId],
    isAdmin: true,
);

echo "=== srv-profiles ===\n";
try {
    $response = (new SrvProfilesController())->index(PluginContext::make(), $pluginRequest);
    echo $response->getContent() . "\n";
} catch (Throwable $e) {
    echo $e::class . ': ' . $e->getMessage() . "\n";
    echo $e->getFile() . ':' . $e->getLine() . "\n";
}

$cnameId = null;
foreach (Services::state(PluginContext::make())->dnsRecords($serverId) as $record) {
    if (($record['type'] ?? '') === 'CNAME') {
        $cnameId = Services::state(PluginContext::make())->recordKey($record);
        break;
    }
}

if ($cnameId && ($argv[2] ?? '') === '--delete-cname') {
    echo "\n=== delete CNAME {$cnameId} ===\n";
    try {
        Services::dns(PluginContext::make())->deleteRecord($serverId, $cnameId);
        echo "delete OK\n";
    } catch (Throwable $e) {
        echo $e::class . ': ' . $e->getMessage() . "\n";
    }
}
