<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\Client;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionData;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class HostnameRegistry
{
    private const STATE_KEY = 'dns_state';

    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly Client $client,
    ) {
    }

    public function isFqdnAvailable(string $fqdn, string $zoneId, ?int $excludeServerId = null): bool
    {
        $fqdn = rtrim(strtolower($fqdn), '.');

        if ($this->isTakenInPluginIndex($fqdn, $excludeServerId)) {
            return false;
        }

        return !$this->existsInCloudflare($fqdn, $zoneId);
    }

    public function isLabelAvailable(
        string $label,
        PrimaryDomain $primaryDomain,
        ?int $excludeServerId = null,
    ): bool {
        $fqdn = RecordName::fqdn(RecordName::normalizeLabel($label), $primaryDomain->domain);

        return $this->isFqdnAvailable($fqdn, $primaryDomain->zoneId, $excludeServerId);
    }

    private function isTakenInPluginIndex(string $fqdn, ?int $excludeServerId): bool
    {
        $records = DnsExtensionData::query()
            ->where('scope', 'server')
            ->where('key', self::STATE_KEY)
            ->get();

        foreach ($records as $record) {
            if ($excludeServerId !== null && (int) $record->subject_id === $excludeServerId) {
                continue;
            }

            $value = $record->value;
            if (!is_array($value)) {
                continue;
            }

            $aName = isset($value['a_record_name']) ? strtolower((string) $value['a_record_name']) : '';
            if ($aName !== '' && $aName === $fqdn) {
                return true;
            }

            $label = isset($value['hostname_label']) ? (string) $value['hostname_label'] : '';
            if ($label === '') {
                continue;
            }

            $domainId = (string) ($value['primary_domain'] ?? 'default');
            $primaryDomain = $this->config->resolvePrimaryDomain($domainId);
            $candidate = strtolower(RecordName::fqdn($label, $primaryDomain->domain));

            if ($candidate === $fqdn) {
                return true;
            }
        }

        return false;
    }

    private function existsInCloudflare(string $fqdn, string $zoneId): bool
    {
        $records = $this->client->listRecords($zoneId, [
            'name' => $fqdn,
            'per_page' => 5,
        ]);

        foreach ($records as $record) {
            $name = isset($record['name']) ? strtolower(rtrim((string) $record['name'], '.')) : '';
            if ($name === $fqdn) {
                return true;
            }
        }

        return false;
    }
}
