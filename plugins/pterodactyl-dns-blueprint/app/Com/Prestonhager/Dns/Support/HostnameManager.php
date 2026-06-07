<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\Client;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\SrvProvisioner;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\ServerSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class HostnameManager
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly Client $client,
        private readonly ServerDnsState $state,
        private readonly SrvProvisioner $provisioner,
        private readonly HostnameRegistry $registry,
    ) {
    }

    public function ensureInitialHostname(int $serverId, ServerSummary $server): string
    {
        $existing = $this->state->hostnameLabel($serverId);
        if ($existing !== null) {
            return $existing;
        }

        $label = $this->generateUniqueLabel($server);
        $this->state->initializeHostname($serverId, $label, 'default', 'auto');

        return $label;
    }

    public function applyLabelChange(
        int $serverId,
        ServerSummary $server,
        string $label,
        string $primaryDomainId,
        bool $countAsChange = true,
        string $mode = 'vanity',
    ): array {
        $label = RecordName::normalizeLabel($label);
        $primaryDomain = $this->config->resolvePrimaryDomain($primaryDomainId);
        $newFqdn = RecordName::fqdn($label, $primaryDomain->domain);
        $oldFqdn = $this->state->aRecordName($serverId);

        $this->renameARecord($serverId, $newFqdn, $primaryDomain->zoneId, $oldFqdn);
        $this->cleanupOrphanSrvRecords($serverId, $label, $oldFqdn, $primaryDomain);

        $this->state->setHostnameLabel($serverId, $label);
        $this->state->setPrimaryDomainId($serverId, $primaryDomain->id);
        $this->state->setHostnameMode($serverId, $mode);

        if ($countAsChange) {
            $this->state->recordLabelChange($serverId, $this->config->clientChangePeriodHours());
        }

        $this->provisioner->provision($serverId, explicitLabel: $label);

        $this->context->activity()->log('subdomain-changed', [
            'server_id' => $serverId,
            'server_uuid' => $server->uuid,
            'label' => $label,
            'fqdn' => $newFqdn,
            'primary_domain' => $primaryDomain->id,
        ]);

        return [
            'hostname_label' => $label,
            'hostname_mode' => $mode,
            'fqdn' => $newFqdn,
            'primary_domain' => $primaryDomain->id,
        ];
    }

    public function regenerate(int $serverId, ServerSummary $server): array
    {
        $label = $this->generateUniqueLabel($server);

        return $this->applyLabelChange($serverId, $server, $label, $this->state->primaryDomainId($serverId), true, 'auto');
    }

    private function generateUniqueLabel(ServerSummary $server): string
    {
        for ($attempt = 0; $attempt < 8; ++$attempt) {
            $label = RecordName::generate($server, $this->config->subdomainGeneration());
            $primaryDomain = $this->config->resolvePrimaryDomain('default');
            if ($this->registry->isLabelAvailable($label, $primaryDomain, $server->id)) {
                return $label;
            }
        }

        return RecordName::generate($server, 'uuid_only');
    }

    private function renameARecord(int $serverId, string $newFqdn, string $zoneId, ?string $oldFqdn): void
    {
        $network = $this->context->servers()->getNetworkSummary($serverId);
        $primary = null;
        foreach ($network->allocations as $allocation) {
            if ($allocation->isPrimary) {
                $primary = $allocation;
                break;
            }
        }

        if (is_null($primary)) {
            return;
        }

        $ip = $primary->ip;
        $existingId = $this->state->aRecordId($serverId);
        $payload = [
            'type' => 'A',
            'name' => $newFqdn,
            'content' => $ip,
            'ttl' => $this->config->defaultTtl(),
            'proxied' => false,
        ];

        if (!is_null($existingId)) {
            $this->client->updateRecord($existingId, $payload, $zoneId);
            $this->state->setARecord($serverId, $existingId, $newFqdn);
            $this->state->upsertRecord($serverId, [
                'cloudflare_id' => $existingId,
                'type' => 'A',
                'name' => $newFqdn,
                'content' => $ip,
                'profile_id' => null,
                'zone_id' => $zoneId,
                'updated_at' => now()->toIso8601String(),
            ]);

            if ($oldFqdn !== null && strtolower($oldFqdn) !== strtolower($newFqdn)) {
                $this->deleteStaleARecord($serverId, $oldFqdn, $existingId, $zoneId);
            }

            return;
        }

        $result = $this->client->createRecord($payload, $zoneId);
        $id = (string) ($result['result']['id'] ?? '');
        if ($id !== '') {
            $this->state->setARecord($serverId, $id, $newFqdn);
            $this->state->upsertRecord($serverId, [
                'cloudflare_id' => $id,
                'type' => 'A',
                'name' => $newFqdn,
                'content' => $ip,
                'profile_id' => null,
                'zone_id' => $zoneId,
                'created_at' => now()->toIso8601String(),
                'updated_at' => now()->toIso8601String(),
            ]);
        }
    }

    private function deleteStaleARecord(int $serverId, string $oldFqdn, string $currentId, string $zoneId): void
    {
        foreach ($this->state->dnsRecords($serverId) as $record) {
            $id = (string) ($record['cloudflare_id'] ?? '');
            $name = strtolower((string) ($record['name'] ?? ''));
            if ($id !== '' && $id !== $currentId && $name === strtolower($oldFqdn) && ($record['type'] ?? '') === 'A') {
                try {
                    $recordZone = (string) ($record['zone_id'] ?? $zoneId);
                    $this->client->deleteRecord($id, $recordZone);
                } catch (\Throwable) {
                }
                $this->state->removeRecord($serverId, $id);
            }
        }
    }

    private function cleanupOrphanSrvRecords(
        int $serverId,
        string $newLabel,
        ?string $oldFqdn,
        PrimaryDomain $primaryDomain,
    ): void {
        if ($oldFqdn === null) {
            return;
        }

        $oldLabel = RecordName::relativeLabel($oldFqdn, $primaryDomain->domain);
        if ($oldLabel === $newLabel) {
            return;
        }

        foreach ($this->state->dnsRecords($serverId) as $record) {
            if (($record['type'] ?? '') !== 'SRV') {
                continue;
            }

            $name = (string) ($record['name'] ?? '');
            if ($name !== '' && str_contains(strtolower($name), '.' . strtolower($oldLabel) . '.')) {
                $id = (string) ($record['cloudflare_id'] ?? '');
                if ($id !== '') {
                    try {
                        $zoneId = (string) ($record['zone_id'] ?? $primaryDomain->zoneId);
                        $this->client->deleteRecord($id, $zoneId);
                    } catch (\Throwable) {
                    }
                    $this->state->removeRecord($serverId, $id);
                }
            }
        }
    }
}
