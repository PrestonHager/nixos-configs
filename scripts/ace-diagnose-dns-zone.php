<?php
require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionSetting;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;

$settings = DnsExtensionSetting::query()->pluck('value', 'key');
echo "zone_id: " . json_encode($settings['zone_id'] ?? null) . "\n";
echo "base_domain: " . json_encode($settings['base_domain'] ?? null) . "\n";
echo "primary_domains: " . json_encode($settings['primary_domains'] ?? null, JSON_PRETTY_PRINT) . "\n";

$context = PluginContext::make();
$config = Services::config($context);
echo "\nresolved zoneId(): " . $config->zoneId() . "\n";
echo "primaryDomains:\n";
foreach ($config->primaryDomains() as $d) {
    echo "  id={$d->id} domain={$d->domain} zoneId={$d->zoneId}\n";
}

$serverId = (int) ($argv[1] ?? 5);
$state = DB::table('dnsrecords_data')->where('scope', 'server')->where('subject_id', $serverId)->where('key', 'dns_state')->value('value');
echo "\nserver {$serverId} dns_state:\n";
echo json_encode($state, JSON_PRETTY_PRINT) . "\n";
