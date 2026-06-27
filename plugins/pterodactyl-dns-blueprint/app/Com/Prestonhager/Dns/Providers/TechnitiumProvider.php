<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Technitium\Client;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class TechnitiumProvider implements DnsProviderInterface
{
    public function __construct(
        private readonly Client $client,
        private readonly Config $config,
    ) {
    }

    public function name(): string
    {
        return 'technitium';
    }

    public function listZones(): array
    {
        return $this->client->listZones();
    }

    public function createRecord(array $payload, string $zoneId): array
    {
        $this->assertNotReserved($payload);
        $result = $this->client->addRecord($payload, $zoneId);

        return $this->normalizeRecord($payload, $result, $zoneId);
    }

    public function updateRecord(string $recordId, array $payload, string $zoneId): array
    {
        $this->assertNotReserved($payload);
        $result = $this->client->addRecord($payload, $zoneId);

        return $this->normalizeRecord($payload, $result, $zoneId);
    }

    public function deleteRecord(string $recordId, string $zoneId, ?array $recordMeta = null): void
    {
        $meta = $recordMeta ?? [];
        $type = (string) ($meta['type'] ?? '');
        $name = (string) ($meta['name'] ?? '');

        if ($type === '' || $name === '') {
            throw new PluginException('Technitium delete requires record type and name.');
        }

        $this->client->deleteRecord(array_merge($meta, [
            'type' => $type,
            'name' => $name,
        ]), $zoneId);
    }

    public function normalizeRecord(array $payload, array $result, string $zoneId): array
    {
        $type = strtoupper((string) ($payload['type'] ?? ''));
        $name = (string) ($payload['name'] ?? '');
        $data = is_array($payload['data'] ?? null) ? $payload['data'] : $payload;
        $recordId = Client::recordKey($zoneId, $name, $type);

        return [
            'provider' => 'technitium',
            'cloudflare_id' => $recordId,
            'record_id' => $recordId,
            'type' => $type,
            'name' => $name,
            'content' => $payload['content'] ?? null,
            'data' => $data,
            'ttl' => $payload['ttl'] ?? $this->config->defaultTtl(),
            'proxied' => false,
            'profile_id' => $payload['profile_id'] ?? null,
            'zone_id' => $zoneId,
            'service' => $data['service'] ?? null,
            'proto' => $data['proto'] ?? null,
            'port' => (int) ($data['port'] ?? 0),
            'target' => (string) ($data['target'] ?? ''),
            'label' => $payload['label'] ?? null,
            'created_at' => $payload['created_at'] ?? now()->toIso8601String(),
            'updated_at' => now()->toIso8601String(),
        ];
    }

    /**
     * @param array<string, mixed> $payload
     */
    private function assertNotReserved(array $payload): void
    {
        $name = (string) ($payload['name'] ?? '');
        $label = strtolower(explode('.', rtrim($name, '.'))[0] ?? '');

        if ($label === '' || $label === '@') {
            return;
        }

        $reserved = array_merge($this->config->reservedLabels(), $this->config->infraReservedLabels());
        if (in_array($label, $reserved, true)) {
            throw new PluginException(sprintf('Label "%s" is reserved for infrastructure records.', $label));
        }
    }
}
