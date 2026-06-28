<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\RecordName;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ResolvedZoneName;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ServerDnsState;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\PrivateNetwork;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\NodeTargetResolver;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\SrvProfile;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ZoneResolver;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\ServerSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class DnsService
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly Client $client,
        private readonly ServerDnsState $state,
        private readonly ZoneResolver $zoneResolver,
        private readonly NodeTargetResolver $nodeTargets,
    ) {
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function listRecordsForServer(int $serverId): array
    {
        return $this->state->dnsRecords($serverId);
    }

    /**
     * @param array<string, mixed> $input
     * @return array<string, mixed>
     */
    public function createRecord(int $serverId, ServerSummary $server, array $input): array
    {
        $type = strtoupper((string) ($input['type'] ?? ''));
        $this->assertAllowedRecord($type, $input, $serverId);
        $built = $this->buildPayload($type, $input, $server, $serverId);
        $providerManager = \Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services::providerManager($this->context);
        $created = $providerManager->createRecord($built['payload'], $built['zone_id'], null, $serverId);

        if ($created === []) {
            throw new PluginException('No DNS provider is configured for record creation.');
        }

        $record = $created[0];
        foreach ($created as $providerRecord) {
            $this->state->upsertRecord($serverId, $providerRecord);
        }

        $this->context->activity()->log('dns-record-created', [
            'server_id' => $serverId,
            'type' => $type,
            'cloudflare_id' => $record['cloudflare_id'] ?? null,
        ]);

        return $record;
    }

    /**
     * @param array<string, mixed> $input
     * @return array<string, mixed>
     */
    public function updateRecord(int $serverId, ServerSummary $server, string $recordId, array $input): array
    {
        $existing = $this->resolveExistingRecord($serverId, $recordId);
        $type = strtoupper((string) ($input['type'] ?? $existing['type'] ?? ''));
        $this->assertAllowedRecord($type, array_merge($existing, $input), $serverId);
        $built = $this->buildPayload($type, array_merge($existing, $input), $server, $serverId, partial: true);
        $zoneId = (string) ($existing['zone_id'] ?? $this->config->zoneId());
        $providerManager = \Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services::providerManager($this->context);
        $updated = $providerManager->updateRecord(
            $this->state->recordKey($existing),
            $built['payload'],
            $zoneId,
            $existing,
            $serverId,
        );
        $record = $updated[0] ?? $existing;

        $this->state->upsertRecord($serverId, $record);
        $this->context->activity()->log('dns-record-updated', [
            'server_id' => $serverId,
            'cloudflare_id' => $this->state->recordKey($record),
        ]);

        return $record;
    }

    public function deleteRecord(int $serverId, string $recordId, ?string $name = null, ?string $type = null): void
    {
        $existing = $this->resolveExistingRecord($serverId, $recordId, $name, $type);
        $providerManager = \Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services::providerManager($this->context);

        foreach ($this->matchingRecords($serverId, $existing) as $record) {
            try {
                $providerManager->deleteRecord($record, $serverId);
            } catch (PluginException) {
            }

            $this->state->removeRecord($serverId, $this->state->recordKey($record));
        }

        $aliasId = $this->state->aRecordId($serverId);
        if (!is_null($aliasId) && ($aliasId === $recordId || $aliasId === ($existing['cloudflare_id'] ?? '') || $aliasId === ($existing['record_id'] ?? ''))) {
            $state = $this->state->all($serverId);
            $state['a_record_id'] = null;
            $state['a_record_name'] = null;
            $this->state->save($serverId, $state);
        }

        $this->context->activity()->log('dns-record-deleted', [
            'server_id' => $serverId,
            'cloudflare_id' => $recordId,
        ]);
    }

    public function deleteAllForServer(int $serverId): void
    {
        $providerManager = \Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services::providerManager($this->context);

        foreach ($this->state->dnsRecords($serverId) as $record) {
            try {
                $providerManager->deleteRecord($record, $serverId);
            } catch (PluginException) {
            }
        }

        $this->state->clear($serverId);
    }

    /**
     * @param array<string, mixed> $input
     * @return array{payload: array<string, mixed>, zone_id: string, resolved: ResolvedZoneName|null}
     */
    private function buildPayload(
        string $type,
        array $input,
        ServerSummary $server,
        int $serverId,
        bool $partial = false,
    ): array {
        $ttl = isset($input['ttl']) ? (int) $input['ttl'] : $this->config->defaultTtl();
        $zoneId = (string) ($input['zone_id'] ?? $this->config->zoneId());

        if ($partial) {
            $resolved = null;
            $name = (string) ($input['name'] ?? '');
        } else {
            $rawName = (string) ($input['name'] ?? RecordName::labelFromServer($server));
            $resolved = $this->zoneResolver->resolve($rawName);
            $name = $resolved->fqdn;
            $zoneId = $resolved->zoneId;
        }

        $payload = [
            'ttl' => $ttl,
            'proxied' => filter_var($input['proxied'] ?? false, FILTER_VALIDATE_BOOLEAN),
        ];

        if (!$partial) {
            $payload['type'] = $type;
            $payload['name'] = $name;
        }

        $payload = match ($type) {
            'A' => array_merge($payload, ['content' => (string) ($input['content'] ?? $input['ip'] ?? '')]),
            'AAAA' => array_merge($payload, ['content' => (string) ($input['content'] ?? '')]),
            'CNAME' => array_merge($payload, ['content' => (string) ($input['content'] ?? $input['target'] ?? '')]),
            'TXT' => array_merge($payload, ['content' => (string) ($input['content'] ?? '')]),
            'MX' => array_merge($payload, [
                'content' => (string) ($input['content'] ?? $input['target'] ?? ''),
                'priority' => (int) ($input['priority'] ?? 10),
            ]),
            'SRV' => $partial || is_null($resolved)
                ? $this->buildSrvPayloadPartial($payload, $input, $serverId)
                : $this->buildSrvPayload($payload, $input, $resolved, $serverId),
            default => throw new PluginException(sprintf('Unsupported DNS record type "%s".', $type)),
        };

        return [
            'payload' => $payload,
            'zone_id' => $zoneId,
            'resolved' => $resolved,
        ];
    }

    /**
     * @param array<string, mixed> $payload
     * @param array<string, mixed> $input
     * @return array<string, mixed>
     */
    private function buildSrvPayloadPartial(array $payload, array $input, int $serverId): array
    {
        $data = is_array($input['data'] ?? null) ? $input['data'] : $input;

        $service = (string) ($data['service'] ?? $input['service'] ?? '_minecraft');
        $proto = (string) ($data['proto'] ?? $input['proto'] ?? '_tcp');
        $port = (int) ($data['port'] ?? $input['port'] ?? 0);
        $target = (string) ($data['target'] ?? $input['target'] ?? '');

        if (!str_starts_with($service, '_')) {
            $service = '_' . $service;
        }
        if (!str_starts_with($proto, '_')) {
            $proto = '_' . $proto;
        }

        if ($port <= 0) {
            $port = $this->primaryAllocationPort($serverId);
        }

        if ($target === '') {
            $target = $this->primaryAllocationTarget($serverId);
        }

        $srvData = [
            'service' => $service,
            'proto' => $proto,
            'priority' => (int) ($data['priority'] ?? $input['priority'] ?? 0),
            'weight' => (int) ($data['weight'] ?? $input['weight'] ?? 5),
            'port' => $port,
            'target' => rtrim($target, '.'),
        ];

        if (isset($data['name']) || isset($input['data']['name'])) {
            $srvData['name'] = (string) ($data['name'] ?? $input['data']['name'] ?? '');
        }

        return array_merge($payload, [
            'data' => $srvData,
        ]);
    }

    /**
     * @param array<string, mixed> $payload
     * @param array<string, mixed> $input
     * @return array<string, mixed>
     */
    private function buildSrvPayload(array $payload, array $input, ResolvedZoneName $hostResolved, int $serverId): array
    {
        $data = is_array($input['data'] ?? null) ? $input['data'] : $input;

        $service = (string) ($data['service'] ?? '_minecraft');
        $proto = (string) ($data['proto'] ?? '_tcp');
        $port = (int) ($data['port'] ?? 0);
        $target = (string) ($data['target'] ?? '');

        if (!str_starts_with($service, '_')) {
            $service = '_' . $service;
        }
        if (!str_starts_with($proto, '_')) {
            $proto = '_' . $proto;
        }

        if ($port <= 0) {
            $port = $this->primaryAllocationPort($serverId);
        }

        if ($target === '') {
            $target = $this->primaryAllocationTarget($serverId);
        }

        $hostLabel = $hostResolved->relativeLabel === '@'
            ? $hostResolved->zoneName
            : $hostResolved->relativeLabel;

        $relative = RecordName::srvRelativeName(
            new SrvProfile('custom', 'custom', $service, $proto),
            $hostLabel
        );

        $srvName = $relative . '.' . $hostResolved->zoneName;

        return array_merge($payload, [
            'type' => 'SRV',
            'name' => $srvName,
            'data' => [
                'service' => $service,
                'proto' => $proto,
                'name' => $hostLabel,
                'priority' => (int) ($data['priority'] ?? 0),
                'weight' => (int) ($data['weight'] ?? 5),
                'port' => $port,
                'target' => rtrim($target, '.'),
            ],
        ]);
    }

    /**
     * @param array<string, mixed> $input
     * @param array{payload: array<string, mixed>, zone_id: string, resolved: ResolvedZoneName|null} $built
     * @return array<string, mixed>
     */
    private function mapCloudflareResult(array $result, array $input, array $built): array
    {
        $data = $result['data'] ?? ($input['data'] ?? null);
        $record = [
            'cloudflare_id' => (string) ($result['id'] ?? ''),
            'type' => (string) ($result['type'] ?? $input['type'] ?? ''),
            'name' => (string) ($result['name'] ?? $input['name'] ?? ''),
            'content' => $result['content'] ?? null,
            'data' => $data,
            'ttl' => $result['ttl'] ?? $this->config->defaultTtl(),
            'proxied' => $result['proxied'] ?? false,
            'profile_id' => $input['profile_id'] ?? null,
            'zone_id' => $built['zone_id'],
            'created_at' => $input['created_at'] ?? now()->toIso8601String(),
            'updated_at' => now()->toIso8601String(),
        ];

        if (is_array($data)) {
            $record['port'] = (int) ($data['port'] ?? $input['port'] ?? 0);
            $record['target'] = (string) ($data['target'] ?? $input['target'] ?? '');
        }

        return $record;
    }

    private function primaryAllocationTarget(int $serverId): string
    {
        return $this->nodeTargets->fqdnForServer($serverId);
    }

    /**
     * @param array<string, mixed> $input
     */
    private function assertAllowedRecord(string $type, array $input, int $serverId): void
    {
        if ($type === 'A') {
            $content = (string) ($input['content'] ?? $input['ip'] ?? '');
            if (PrivateNetwork::isPrivateLan($content)) {
                throw new PluginException(
                    'A records must not use private LAN addresses. Use a CNAME to the node FQDN (for example '
                    . $this->nodeTargets->fqdnForServer($serverId)
                    . ') or rely on SRV records instead.'
                );
            }
        }
    }

    /**
     * @return array<string, mixed>
     */
    private function resolveExistingRecord(int $serverId, string $recordId, ?string $name = null, ?string $type = null): array
    {
        $recordId = rawurldecode(trim($recordId));

        if ($recordId !== '') {
            $existing = $this->state->findRecord($serverId, $recordId);
            if (!is_null($existing)) {
                return $existing;
            }
        }

        if ($name !== null && $type !== null && $name !== '' && $type !== '') {
            $byName = $this->state->findRecordByNameAndType($serverId, $name, $type);
            if (!is_null($byName)) {
                return $byName;
            }
        }

        if (str_starts_with($recordId, 'technitium:')) {
            $parts = explode(':', $recordId, 4);
            if (count($parts) === 4) {
                $byName = $this->state->findRecordByNameAndType($serverId, $parts[2], $parts[3]);
                if (!is_null($byName)) {
                    return $byName;
                }
            }
        }

        $aliasId = $this->state->aRecordId($serverId);
        if (!is_null($aliasId) && $aliasId !== '') {
            $aliasRecord = $this->state->findRecord($serverId, $aliasId);
            if (!is_null($aliasRecord)) {
                if ($recordId === '' || $this->state->recordKey($aliasRecord) === $recordId) {
                    return $aliasRecord;
                }
            }
        }

        throw new PluginException('DNS record not found for this server.');
    }

    /**
     * @param array<string, mixed> $existing
     * @return array<int, array<string, mixed>>
     */
    private function matchingRecords(int $serverId, array $existing): array
    {
        $name = strtolower(rtrim((string) ($existing['name'] ?? ''), '.'));
        $type = strtoupper((string) ($existing['type'] ?? ''));
        $matches = [];

        foreach ($this->state->dnsRecords($serverId) as $record) {
            $recordName = strtolower(rtrim((string) ($record['name'] ?? ''), '.'));
            $recordType = strtoupper((string) ($record['type'] ?? ''));

            if ($recordName === $name && $recordType === $type) {
                $matches[] = $record;
            }
        }

        return $matches !== [] ? $matches : [$existing];
    }

    private function primaryAllocationPort(int $serverId): int
    {
        $network = $this->context->servers()->getNetworkSummary($serverId);

        foreach ($network->allocations as $allocation) {
            if ($allocation->isPrimary) {
                return $allocation->port;
            }
        }

        throw new PluginException('No primary allocation found for this server.');
    }
}
