<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\Client;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class ZoneResolver
{
    /** @var array<string, string>|null zone name => zone id */
    private ?array $zones = null;

    public function __construct(
        private readonly Client $client,
        private readonly Config $config,
    ) {
    }

    public function resolve(string $input, ?string $defaultZoneId = null, ?string $defaultBaseDomain = null): ResolvedZoneName
    {
        $defaultZoneId ??= $this->config->zoneId();
        $defaultBaseDomain ??= $this->config->baseDomain();

        $normalized = $this->normalizeInput($input);
        if ($normalized === '') {
            throw new PluginException('DNS record name is required.');
        }

        $lowerBase = strtolower($defaultBaseDomain);

        if (strcasecmp($normalized, $defaultBaseDomain) === 0) {
            return new ResolvedZoneName(
                fqdn: $normalized,
                relativeLabel: '@',
                zoneId: $defaultZoneId,
                zoneName: $defaultBaseDomain,
                inDefaultZone: true,
            );
        }

        if (str_ends_with(strtolower($normalized), '.' . $lowerBase)) {
            $relative = substr($normalized, 0, -(strlen($defaultBaseDomain) + 1));

            return new ResolvedZoneName(
                fqdn: $normalized,
                relativeLabel: $relative !== '' ? $relative : '@',
                zoneId: $defaultZoneId,
                zoneName: $defaultBaseDomain,
                inDefaultZone: true,
            );
        }

        if (!str_contains($normalized, '.')) {
            $fqdn = $normalized . '.' . $defaultBaseDomain;

            return new ResolvedZoneName(
                fqdn: $fqdn,
                relativeLabel: $normalized,
                zoneId: $defaultZoneId,
                zoneName: $defaultBaseDomain,
                inDefaultZone: true,
            );
        }

        if ($this->isRelativeSubdomain($normalized, $defaultBaseDomain)) {
            $fqdn = $normalized . '.' . $defaultBaseDomain;

            return new ResolvedZoneName(
                fqdn: $fqdn,
                relativeLabel: $normalized,
                zoneId: $defaultZoneId,
                zoneName: $defaultBaseDomain,
                inDefaultZone: true,
            );
        }

        $match = $this->findZoneForFqdn($normalized);
        if (is_null($match)) {
            throw new PluginException(sprintf(
                'No Cloudflare zone found for "%s". Ensure the token can list zones and the domain is in your account.',
                $normalized
            ));
        }

        [$zoneId, $zoneName] = $match;
        $relative = $this->relativeLabelInZone($normalized, $zoneName);

        return new ResolvedZoneName(
            fqdn: $normalized,
            relativeLabel: $relative,
            zoneId: $zoneId,
            zoneName: $zoneName,
            inDefaultZone: $zoneId === $defaultZoneId,
        );
    }

    private function normalizeInput(string $input): string
    {
        $input = trim($input);

        return rtrim($input, '.');
    }

    private function isRelativeSubdomain(string $name, string $baseDomain): bool
    {
        if (str_ends_with(strtolower($name), '.' . strtolower($baseDomain))) {
            return false;
        }

        if (!str_contains($name, '.')) {
            return false;
        }

        return !$this->looksLikeExternalFqdn($name, $baseDomain);
    }

    private function looksLikeExternalFqdn(string $name, string $baseDomain): bool
    {
        $parts = explode('.', $name);
        if (count($parts) < 2) {
            return false;
        }

        $tld = strtolower(end($parts));
        if (!preg_match('/^[a-z]{2,63}$/', $tld)) {
            return false;
        }

        $lowerName = strtolower($name);
        $lowerBase = strtolower($baseDomain);

        if ($lowerName === $lowerBase || str_ends_with($lowerName, '.' . $lowerBase)) {
            return false;
        }

        return true;
    }

    /**
     * @return array{0: string, 1: string}|null
     */
    private function findZoneForFqdn(string $fqdn): ?array
    {
        $lowerFqdn = strtolower($fqdn);
        $bestMatch = null;
        $bestLength = -1;

        foreach ($this->loadZones() as $zoneName => $zoneId) {
            $lowerZone = strtolower($zoneName);
            if ($lowerFqdn === $lowerZone || str_ends_with($lowerFqdn, '.' . $lowerZone)) {
                $length = strlen($lowerZone);
                if ($length > $bestLength) {
                    $bestLength = $length;
                    $bestMatch = [$zoneId, $zoneName];
                }
            }
        }

        return $bestMatch;
    }

    private function relativeLabelInZone(string $fqdn, string $zoneName): string
    {
        $lowerFqdn = strtolower($fqdn);
        $lowerZone = strtolower($zoneName);

        if ($lowerFqdn === $lowerZone) {
            return '@';
        }

        $suffix = '.' . $lowerZone;
        if (str_ends_with($lowerFqdn, $suffix)) {
            return substr($fqdn, 0, -strlen($suffix));
        }

        return $fqdn;
    }

    /**
     * @return array<string, string> zone name => zone id
     */
    private function loadZones(): array
    {
        if (!is_null($this->zones)) {
            return $this->zones;
        }

        $this->zones = [];
        $page = 1;

        do {
            $response = $this->client->listZones(['page' => $page, 'per_page' => 50]);
            $results = $response['result'] ?? [];

            if (!is_array($results)) {
                break;
            }

            foreach ($results as $zone) {
                if (!is_array($zone)) {
                    continue;
                }

                $id = isset($zone['id']) ? (string) $zone['id'] : '';
                $name = isset($zone['name']) ? (string) $zone['name'] : '';
                if ($id !== '' && $name !== '') {
                    $this->zones[$name] = $id;
                }
            }

            $resultInfo = $response['result_info'] ?? [];
            $totalPages = is_array($resultInfo) ? (int) ($resultInfo['total_pages'] ?? 1) : 1;
            ++$page;
        } while ($page <= $totalPages);

        return $this->zones;
    }
}
