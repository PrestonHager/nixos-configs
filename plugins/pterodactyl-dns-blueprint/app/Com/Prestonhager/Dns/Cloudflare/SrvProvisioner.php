<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\RecordName;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ServerDnsState;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\SrvProfile;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\AllocationSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\ServerSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\NodeTargetResolver;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\PrivateNetwork;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers\ProviderManager;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class SrvProvisioner
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly Client $client,
        private readonly ServerDnsState $state,
        private readonly SrvRecordMatcher $matcher,
        private readonly ProviderManager $providers,
        private readonly NodeTargetResolver $nodeTargets,
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
        $aliasFqdn = RecordName::fqdn($label, $baseDomain);
        $nodeFqdn = $this->nodeTargets->fqdnForServer($serverId);
        $zoneId = $primaryDomain->zoneId;

        $this->ensureHostnameAlias($serverId, $aliasFqdn, $nodeFqdn, $zoneId);

        $targetCandidates = $this->targetCandidates($nodeFqdn, $primary, $aliasFqdn, $serverId);
        $localRecords = $this->state->dnsRecords($serverId);

        foreach ($profiles as $profile) {
            $this->provisionSrvProfile(
                $serverId,
                $network->server,
                $profile,
                $label,
                $nodeFqdn,
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
    private function targetCandidates(string $currentTarget, AllocationSummary $primary, string $aliasFqdn, int $serverId): array
    {
        $nodeFqdn = $this->nodeTargets->fqdnForServer($serverId);
        $candidates = array_filter([
            $currentTarget,
            $nodeFqdn,
            $primary->ipAlias,
            $aliasFqdn,
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

    private function ensureHostnameAlias(int $serverId, string $fqdn, string $nodeFqdn, string $zoneId): void
    {
        $this->removeStaleLanARecords($serverId, $fqdn, $zoneId);

        $payload = [
            'type' => 'CNAME',
            'name' => $fqdn,
            'content' => $nodeFqdn,
            'ttl' => $this->config->defaultTtl(),
            'proxied' => false,
        ];

        $existingId = $this->state->aRecordId($serverId);
        if (!is_null($existingId)) {
            $existing = $this->state->findRecord($serverId, $existingId);
            if (!is_null($existing)) {
                if (($existing['type'] ?? '') === 'CNAME' && strtolower(rtrim((string) ($existing['content'] ?? ''), '.')) === strtolower($nodeFqdn)) {
                    $this->ensureAliasMirrors($serverId, $payload, $zoneId);

                    return;
                }

                if (($existing['type'] ?? '') !== 'CNAME') {
                    try {
                        $this->providers->deleteRecord($existing, $serverId);
                    } catch (\Throwable) {
                    }
                    $this->state->removeRecord($serverId, $this->state->recordKey($existing));
                    $existing = null;
                }
            }

            if (!is_null($existing)) {
                $updated = $this->providers->updateRecord($existingId, $payload, $zoneId, $existing, $serverId);
                foreach ($updated as $record) {
                    $this->state->upsertRecord($serverId, $record);
                    $this->state->setARecord($serverId, $this->state->recordKey($record), $fqdn);
                }

                return;
            }
        }

        $created = $this->providers->createRecord($payload, $zoneId, null, $serverId);
        foreach ($created as $record) {
            $id = $this->state->recordKey($record);
            if ($id !== '') {
                $this->state->setARecord($serverId, $id, $fqdn);
                $this->state->upsertRecord($serverId, $record);
            }
        }
    }

    /**
     * When the alias already exists on its owning provider, make sure every
     * other enabled provider also has it (mode "both" keeps providers in sync).
     *
     * @param array<string, mixed> $payload
     */
    private function ensureAliasMirrors(int $serverId, array $payload, string $zoneId): void
    {
        $records = $this->state->dnsRecords($serverId);
        $expectedTarget = strtolower(rtrim((string) ($payload['content'] ?? ''), '.'));
        $expectedName = strtolower(rtrim((string) ($payload['name'] ?? ''), '.'));

        foreach ($this->providers->providersFor() as $provider) {
            $covered = false;
            foreach ($records as $record) {
                if (($record['type'] ?? '') !== 'CNAME'
                    || ($record['provider'] ?? 'cloudflare') !== $provider->name()) {
                    continue;
                }
                if (strtolower(rtrim((string) ($record['name'] ?? ''), '.')) === $expectedName
                    && strtolower(rtrim((string) ($record['content'] ?? ''), '.')) === $expectedTarget) {
                    $covered = true;
                    break;
                }
            }
            if ($covered) {
                continue;
            }

            try {
                $created = $provider->createRecord($payload, $provider->name() === 'technitium'
                    ? $this->config->technitiumDefaultZone()
                    : $zoneId);
                $this->state->upsertRecord($serverId, $created);
                $id = $this->state->recordKey($created);
                if ($id !== '') {
                    $this->state->setARecord($serverId, $id, (string) ($payload['name'] ?? ''));
                }
            } catch (\Throwable) {
                continue;
            }
        }
    }

    private function removeStaleLanARecords(int $serverId, string $fqdn, string $zoneId): void
    {
        foreach ($this->state->dnsRecords($serverId) as $record) {
            if (($record['type'] ?? '') !== 'A') {
                continue;
            }

            $name = strtolower(rtrim((string) ($record['name'] ?? ''), '.'));
            if ($name !== strtolower(rtrim($fqdn, '.'))) {
                continue;
            }

            $content = (string) ($record['content'] ?? '');
            if (!PrivateNetwork::isPrivateLan($content)) {
                continue;
            }

            try {
                $this->providers->deleteRecord($record, $serverId);
            } catch (\Throwable) {
            }

            $this->state->removeRecord($serverId, $this->state->recordKey($record));
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

        $providerOverride = $profile->targetProvider ?? null;

        if (!is_null($existing) && !empty($existing['cloudflare_id'])) {
            $updated = $this->providers->updateRecord(
                (string) $existing['cloudflare_id'],
                array_merge($payload, ['profile_id' => $profile->id, 'label' => $profile->label]),
                $zoneId,
                $existing,
                $serverId,
            );
            foreach ($updated as $record) {
                $this->state->upsertRecord($serverId, $record);
            }

            return;
        }

        $created = $this->providers->createRecord(
            array_merge($payload, ['profile_id' => $profile->id, 'label' => $profile->label]),
            $zoneId,
            $providerOverride,
            $serverId,
        );
        foreach ($created as $record) {
            $this->state->upsertRecord($serverId, $record);
        }

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
