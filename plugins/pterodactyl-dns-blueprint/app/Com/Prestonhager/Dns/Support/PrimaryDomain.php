<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

readonly class PrimaryDomain
{
    public function __construct(
        public string $id,
        public string $domain,
        public string $zoneId,
        public bool $clientSelectable,
    ) {
    }

    /**
     * @param array<string, mixed> $entry
     */
    public static function fromConfigEntry(array $entry, string $defaultZoneId, string $defaultDomain): ?self
    {
        $domain = trim((string) ($entry['domain'] ?? ''));
        if ($domain === '') {
            return null;
        }

        $id = trim((string) ($entry['id'] ?? ''));
        if ($id === '') {
            $id = preg_replace('/[^a-z0-9]+/', '-', strtolower($domain)) ?? $domain;
        }

        $zoneId = trim((string) ($entry['zone_id'] ?? ''));
        if ($zoneId === '' || !CloudflareZoneId::isZoneId($zoneId)) {
            $zoneId = CloudflareZoneId::normalize($zoneId, $defaultZoneId, $defaultDomain, $domain);
        }

        return new self(
            id: $id,
            domain: rtrim($domain, '.'),
            zoneId: $zoneId,
            clientSelectable: filter_var($entry['client_selectable'] ?? true, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) ?? true,
        );
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(bool $exposeZoneId = false): array
    {
        $data = [
            'id' => $this->id,
            'domain' => $this->domain,
            'client_selectable' => $this->clientSelectable,
        ];

        if ($exposeZoneId) {
            $data['zone_id'] = $this->zoneId;
        }

        return $data;
    }
}
