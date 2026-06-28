<?php
require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

use Illuminate\Http\Request;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\SubdomainController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;

$serverId = (int) ($argv[1] ?? 5);
$primaryDomain = (string) ($argv[2] ?? 'games');
$admin = \Pterodactyl\Models\User::query()->where('root_admin', true)->first();

$state = Services::state(PluginContext::make());
$label = $state->hostnameLabel($serverId) ?? 'minecraft-server-ead-662ba6f7';

$pluginRequest = new PluginHttpRequest(
    request: Request::create("/extensions/dnsrecords/admin/servers/{$serverId}/subdomain", 'PUT', [
        'label' => $label,
        'primary_domain' => $primaryDomain,
        'subdomain_locked' => false,
    ]),
    userId: $admin?->id,
    serverId: $serverId,
    body: [
        'label' => $label,
        'primary_domain' => $primaryDomain,
        'subdomain_locked' => false,
    ],
    query: [],
    route: ['server' => $serverId],
    isAdmin: true,
);

echo "Updating server {$serverId} primary_domain={$primaryDomain} label={$label}\n";

$games = Services::config(PluginContext::make())->resolvePrimaryDomain($primaryDomain);
echo "Resolved games domain zoneId={$games->zoneId} domain={$games->domain}\n";

try {
    $response = (new SubdomainController())->update(PluginContext::make(), $pluginRequest);
    echo $response->getContent() . "\n";
    echo "OK\n";
} catch (Throwable $e) {
    echo $e::class . ': ' . $e->getMessage() . "\n";
    exit(1);
}
