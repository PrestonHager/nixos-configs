<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\Client;

class CloudflareProvider implements DnsProviderInterface
{
    public function __construct(
        private readonly Client $client,
    ) {
    }

    public function name(): string
    {
        return 'cloudflare';
    }

    public function listZones(): array
    {
        $response = $this->client->listZones();

        return is_array($response['result'] ?? null) ? $response['result'] : [];
    }

    public function createRecord(array $payload, string $zoneId): array
    {
        $result = $this->client->createRecord($payload, $zoneId);

        return $this->normalizeRecord($payload, $result['result'] ?? [], $zoneId);
    }

    public function updateRecord(string $recordId, array $payload, string $zoneId): array
    {
        $result = $this->client->updateRecord($recordId, $payload, $zoneId);

        return $this->normalizeRecord($payload, $result['result'] ?? [], $zoneId);
    }

    public function deleteRecord(string $recordId, string $zoneId, ?array $recordMeta = null): void
    {
        $this->client->deleteRecord($recordId, $zoneId);
    }

    public function normalizeRecord(array $payload, array $result, string $zoneId): array
    {
        $data = $result['data'] ?? ($payload['data'] ?? null);
        $record = [
            'provider' => 'cloudflare',
            'cloudflare_id' => (string) ($result['id'] ?? ''),
            'record_id' => (string) ($result['id'] ?? ''),
            'type' => (string) ($result['type'] ?? $payload['type'] ?? ''),
            'name' => (string) ($result['name'] ?? $payload['name'] ?? ''),
            'content' => $result['content'] ?? null,
            'data' => $data,
            'ttl' => $result['ttl'] ?? ($payload['ttl'] ?? 1),
            'proxied' => $result['proxied'] ?? false,
            'profile_id' => $payload['profile_id'] ?? null,
            'zone_id' => $zoneId,
            'created_at' => $payload['created_at'] ?? now()->toIso8601String(),
            'updated_at' => now()->toIso8601String(),
        ];

        if (is_array($data)) {
            $record['port'] = (int) ($data['port'] ?? $payload['port'] ?? 0);
            $record['target'] = (string) ($data['target'] ?? $payload['target'] ?? '');
        }

        return $record;
    }
}
