<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

/**
 * Cloudflare zone identifiers are 32-character hex strings.
 * Domain names (e.g. prestonhager.com) must never appear in /zones/{id}/ API paths.
 */
final class CloudflareZoneId
{
    public static function isZoneId(string $value): bool
    {
        return (bool) preg_match('/^[a-f0-9]{32}$/i', trim($value));
    }

    /**
     * Resolve a configured zone reference to a Cloudflare zone ID.
     *
     * Primary domain entries often omit zone_id or mistakenly set it to a DNS zone
     * name (prestonhager.com). Vanity bases like games.prestonhager.com still
     * live in the parent Cloudflare zone (prestonhager.com).
     */
    public static function normalize(
        string $value,
        string $defaultZoneId,
        string $defaultDomain,
        string $hostnameBase = '',
    ): string {
        $value = trim($value);
        $defaultZoneId = trim($defaultZoneId);

        if ($value !== '' && self::isZoneId($value)) {
            return strtolower($value);
        }

        if (self::isZoneId($defaultZoneId)) {
            if ($value === '' || self::isParentZoneName($value, $defaultDomain, $hostnameBase)) {
                return strtolower($defaultZoneId);
            }
        }

        if ($value !== '' && self::isZoneId($value)) {
            return strtolower($value);
        }

        if (self::isZoneId($defaultZoneId)) {
            return strtolower($defaultZoneId);
        }

        return $value;
    }

    private static function isParentZoneName(string $zoneName, string $defaultDomain, string $hostnameBase): bool
    {
        $zoneName = strtolower(rtrim($zoneName, '.'));
        $defaultDomain = strtolower(rtrim($defaultDomain, '.'));
        $hostnameBase = strtolower(rtrim($hostnameBase, '.'));

        if ($zoneName === $defaultDomain) {
            return true;
        }

        if ($hostnameBase !== '' && ($hostnameBase === $zoneName || str_ends_with($hostnameBase, '.' . $zoneName))) {
            return true;
        }

        if ($hostnameBase !== '' && str_ends_with($hostnameBase, '.' . $defaultDomain)) {
            return true;
        }

        return false;
    }
}
