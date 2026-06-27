<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers;

interface DnsProviderInterface
{
    public function name(): string;

    /**
     * @return array<int, array<string, mixed>>
     */
    public function listZones(): array;

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    public function createRecord(array $payload, string $zoneId): array;

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    public function updateRecord(string $recordId, array $payload, string $zoneId): array;

    public function deleteRecord(string $recordId, string $zoneId, ?array $recordMeta = null): void;

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed> Normalized record for ServerDnsState
     */
    public function normalizeRecord(array $payload, array $result, string $zoneId): array;
}
