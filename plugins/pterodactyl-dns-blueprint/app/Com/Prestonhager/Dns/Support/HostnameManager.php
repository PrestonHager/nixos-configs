<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\Client;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\SrvProvisioner;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers\ProviderManager;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\NodeTargetResolver;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\PrivateNetwork;
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
        private readonly ProviderManager $providers,
        private readonly NodeTargetResolver $nodeTargets,
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

        $this->renameHostnameAlias($serverId, $newFqdn, $primaryDomain->zoneId, $oldFqdn);
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

    private function renameHostnameAlias(int $serverId, string $newFqdn, string $zoneId, ?string $oldFqdn): void
    {
        $nodeFqdn = $this->nodeTargets->fqdnForServer($serverId);
        $existingId = $this->state->aRecordId($serverId);
        $payload = [
            'type' => 'CNAME',
            'name' => $newFqdn,
            'content' => $nodeFqdn,
            'ttl' => $this->config->defaultTtl(),
            'proxied' => false,
        ];

        if (!is_null($existingId)) {
            $existing = $this->state->findRecord($serverId, $existingId);
            if (!is_null($existing)) {
                if (($existing['type'] ?? '') === 'A' && PrivateNetwork::isPrivateLan((string) ($existing['content'] ?? ''))) {
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
                    $this->state->setARecord($serverId, $this->state->recordKey($record), $newFqdn);
                }

                if ($oldFqdn !== null && strtolower($oldFqdn) !== strtolower($newFqdn)) {
                    $this->deleteStaleAliasRecord($serverId, $oldFqdn, $this->state->recordKey($updated[0] ?? $existing), $zoneId);
                }

                return;
            }
        }

        $created = $this->providers->createRecord($payload, $zoneId, null, $serverId);
        foreach ($created as $record) {
            $id = $this->state->recordKey($record);
            if ($id !== '') {
                $this->state->setARecord($serverId, $id, $newFqdn);
                $this->state->upsertRecord($serverId, $record);
            }
        }
    }

    private function deleteStaleAliasRecord(int $serverId, string $oldFqdn, string $currentId, string $zoneId): void
    {
        foreach ($this->state->dnsRecords($serverId) as $record) {
            $id = $this->state->recordKey($record);
            $name = strtolower((string) ($record['name'] ?? ''));
            $type = strtoupper((string) ($record['type'] ?? ''));
            if ($id !== '' && $id !== $currentId && $name === strtolower($oldFqdn) && in_array($type, ['A', 'CNAME'], true)) {
                try {
                    $this->providers->deleteRecord($record, $serverId);
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
                $id = $this->state->recordKey($record);
                if ($id !== '') {
                    try {
                        $zoneId = (string) ($record['zone_id'] ?? $primaryDomain->zoneId);
                        $this->providers->deleteRecord($record, $serverId);
                    } catch (\Throwable) {
                    }
                    $this->state->removeRecord($serverId, $id);
                }
            }
        }
    }
}
