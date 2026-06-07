<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\RecordName;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ServerDnsState;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\SrvProfile;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\AllocationSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\ServerSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class SrvProvisioner
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly Client $client,
        private readonly ServerDnsState $state,
        private readonly SrvRecordMatcher $matcher,
    ) {
    }

    public function provision(int $serverId, ?array $profileIds = null, ?string $explicitLabel = null): void
    {
        $network = $this->context->servers()->getNetworkSummary($serverId);
        $primary = $this->primaryAllocation($network->allocations);

        if (is_null($primary)) {
            return;
        }

        $profiles = $this->resolveProfiles($serverId, $profileIds);
        if ($profiles === []) {
            return;
        }

        $primaryDomain = $this->config->resolvePrimaryDomain($this->state->primaryDomainId($serverId));
        $label = $explicitLabel ?? $this->state->hostnameLabel($serverId);
        if ($label === null || $label === '') {
            $label = RecordName::generate($network->server, $this->config->subdomainGeneration());
            $this->state->initializeHostname($serverId, $label, $primaryDomain->id, 'auto');
        }

        $baseDomain = $primaryDomain->domain;
        $aFqdn = RecordName::fqdn($label, $baseDomain);
        $target = $this->allocationTarget($primary);
        $zoneId = $primaryDomain->zoneId;

        $this->ensureARecord($serverId, $aFqdn, $primary->ip, $zoneId);

        $targetCandidates = $this->targetCandidates($target, $primary, $aFqdn, $serverId);
        $localRecords = $this->state->dnsRecords($serverId);

        foreach ($profiles as $profile) {
            $this->provisionSrvProfile(
                $serverId,
                $network->server,
                $profile,
                $label,
                $target,
                $primary->port,
                $zoneId,
                $baseDomain,
                $targetCandidates,
                $localRecords,
            );
        }
    }

    /**
     * @param AllocationSummary[] $allocations
     */
    private function primaryAllocation(array $allocations): ?AllocationSummary
    {
        foreach ($allocations as $allocation) {
            if ($allocation->isPrimary) {
                return $allocation;
            }
        }

        return null;
    }

    private function allocationTarget(AllocationSummary $allocation): string
    {
        return ($allocation->ipAlias !== null && $allocation->ipAlias !== '')
            ? $allocation->ipAlias
            : $allocation->ip;
    }

    /**
     * @return string[]
     */
    private function targetCandidates(string $currentTarget, AllocationSummary $primary, string $aFqdn, int $serverId): array
    {
        $candidates = array_filter([
            $currentTarget,
            $primary->ip,
            $primary->ipAlias,
            $aFqdn,
            $this->state->aRecordName($serverId),
        ], fn ($value) => is_string($value) && $value !== '');

        foreach ($this->state->dnsRecords($serverId) as $record) {
            if (($record['type'] ?? '') === 'SRV') {
                $stored = $record['target'] ?? ($record['data']['target'] ?? null);
                if (is_string($stored) && $stored !== '') {
                    $candidates[] = $stored;
                }
            }
        }

        return array_values(array_unique($candidates));
    }

    /**
     * @return SrvProfile[]
     */
    private function resolveProfiles(int $serverId, ?array $profileIds): array
    {
        $available = $this->config->srvProfiles();
        if ($available === []) {
            return [];
        }

        $enabledIds = $profileIds ?? $this->state->srvProfileIds($serverId);
        if ($enabledIds === []) {
            $enabledIds = array_map(
                fn (SrvProfile $profile) => $profile->id,
                array_filter($available, fn (SrvProfile $p) => $p->autoProvision)
            );
            $this->state->setSrvProfileIds($serverId, $enabledIds);
        }

        $byId = [];
        foreach ($available as $profile) {
            $byId[$profile->id] = $profile;
        }

        $selected = [];
        foreach ($enabledIds as $id) {
            if (isset($byId[$id])) {
                $selected[] = $byId[$id];
            }
        }

        return $selected;
    }

    private function ensureARecord(int $serverId, string $fqdn, string $ip, string $zoneId): void
    {
        $existingId = $this->state->aRecordId($serverId);
        $payload = [
            'type' => 'A',
            'name' => $fqdn,
            'content' => $ip,
            'ttl' => $this->config->defaultTtl(),
            'proxied' => false,
        ];

        if (!is_null($existingId)) {
            $this->client->updateRecord($existingId, $payload, $zoneId);
            $this->state->setARecord($serverId, $existingId, $fqdn);

            return;
        }

        $result = $this->client->createRecord($payload, $zoneId);
        $id = (string) ($result['result']['id'] ?? '');
        if ($id !== '') {
            $this->state->setARecord($serverId, $id, $fqdn);
            $this->state->upsertRecord($serverId, [
                'cloudflare_id' => $id,
                'type' => 'A',
                'name' => $fqdn,
                'content' => $ip,
                'profile_id' => null,
                'zone_id' => $zoneId,
                'created_at' => now()->toIso8601String(),
                'updated_at' => now()->toIso8601String(),
            ]);
        }
    }

    /**
     * @param string[] $targetCandidates
     * @param array<int, array<string, mixed>> $localRecords
     */
    private function provisionSrvProfile(
        int $serverId,
        ServerSummary $server,
        SrvProfile $profile,
        string $label,
        string $targetHost,
        int $allocationPort,
        string $zoneId,
        string $baseDomain,
        array $targetCandidates,
        array $localRecords,
    ): void {
        $port = $profile->port ?? $allocationPort;
        $relative = RecordName::srvRelativeName($profile, $label);
        $name = $relative . '.' . $baseDomain;

        $payload = [
            'type' => 'SRV',
            'name' => $name,
            'ttl' => $this->config->defaultTtl(),
            'proxied' => false,
            'data' => [
                'service' => $profile->service,
                'proto' => $profile->proto,
                'name' => $label,
                'priority' => $profile->priority,
                'weight' => $profile->weight,
                'port' => $port,
                'target' => rtrim($targetHost, '.'),
            ],
        ];

        $existing = $this->matcher->findExisting(
            $profile,
            $name,
            $port,
            $targetCandidates,
            $localRecords,
            $zoneId,
        );

        if (!is_null($existing) && !empty($existing['cloudflare_id'])) {
            $result = $this->client->updateRecord((string) $existing['cloudflare_id'], $payload, $zoneId);
            $mapped = $this->mapSrvResult($result['result'] ?? [], $profile, $port, $targetHost, $zoneId);
            $this->state->upsertRecord($serverId, $mapped);

            return;
        }

        $result = $this->client->createRecord($payload, $zoneId);
        $mapped = $this->mapSrvResult($result['result'] ?? [], $profile, $port, $targetHost, $zoneId);
        $this->state->upsertRecord($serverId, $mapped);

        $this->context->activity()->log('srv-record-provisioned', [
            'server_id' => $serverId,
            'server_uuid' => $server->uuid,
            'profile_id' => $profile->id,
            'service' => $profile->service,
            'proto' => $profile->proto,
            'port' => $port,
        ]);
    }

    /**
     * @param array<string, mixed> $result
     * @return array<string, mixed>
     */
    private function mapSrvResult(array $result, SrvProfile $profile, int $port, string $target, string $zoneId): array
    {
        return [
            'cloudflare_id' => (string) ($result['id'] ?? ''),
            'type' => 'SRV',
            'name' => (string) ($result['name'] ?? ''),
            'data' => $result['data'] ?? null,
            'profile_id' => $profile->id,
            'service' => $profile->service,
            'proto' => $profile->proto,
            'port' => $port,
            'target' => rtrim($target, '.'),
            'label' => $profile->label,
            'zone_id' => $zoneId,
            'created_at' => now()->toIso8601String(),
            'updated_at' => now()->toIso8601String(),
        ];
    }
}
