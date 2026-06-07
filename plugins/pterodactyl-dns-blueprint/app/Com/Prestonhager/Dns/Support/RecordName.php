<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\ServerSummary;

class RecordName
{
    public static function generate(ServerSummary $server, string $strategy = 'server_slug'): string
    {
        return match ($strategy) {
            'random_words' => self::randomWordsLabel(),
            'random_hex' => self::randomHexLabel(),
            'uuid_only' => self::uuidOnlyLabel($server),
            default => self::labelFromServer($server),
        };
    }

    public static function labelFromServer(ServerSummary $server): string
    {
        $base = strtolower($server->name);
        $base = preg_replace('/[^a-z0-9]+/', '-', $base) ?? 'server';
        $base = trim($base, '-');

        if ($base === '') {
            $base = 'server';
        }

        $suffix = substr(str_replace('-', '', $server->uuid), 0, 8);

        return substr($base, 0, 48) . '-' . $suffix;
    }

    public static function normalizeLabel(string $label): string
    {
        return strtolower(trim($label));
    }

    public static function isValidLabel(string $label, int $minLength = 3, int $maxLength = 32): bool
    {
        $label = self::normalizeLabel($label);
        $length = strlen($label);

        if ($length < $minLength || $length > $maxLength) {
            return false;
        }

        if (!preg_match('/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/', $label)) {
            return false;
        }

        if (str_contains($label, '--')) {
            return false;
        }

        if (str_starts_with($label, '_') || str_contains($label, '._')) {
            return false;
        }

        return !preg_match('/[^\x00-\x7F]/', $label);
    }

    private static function randomWordsLabel(): string
    {
        $words = [
            'alpha', 'beta', 'gamma', 'delta', 'echo', 'foxtrot', 'golf', 'hotel',
            'india', 'juliet', 'kilo', 'lima', 'mike', 'nova', 'oscar', 'papa',
            'quebec', 'romeo', 'sierra', 'tango', 'ultra', 'victor', 'whiskey',
            'xray', 'yankee', 'zulu', 'amber', 'bronze', 'coral', 'drift', 'ember',
        ];

        $first = $words[random_int(0, count($words) - 1)];
        $second = $words[random_int(0, count($words) - 1)];
        $suffix = substr(bin2hex(random_bytes(2)), 0, 4);

        return $first . '-' . $second . '-' . $suffix;
    }

    private static function randomHexLabel(): string
    {
        return 'srv-' . bin2hex(random_bytes(4));
    }

    private static function uuidOnlyLabel(ServerSummary $server): string
    {
        return substr(str_replace('-', '', $server->uuid), 0, 12);
    }

    public static function fqdn(string $label, string $baseDomain): string
    {
        return $label . '.' . rtrim($baseDomain, '.');
    }

    public static function srvRelativeName(SrvProfile $profile, string $label): string
    {
        $service = ltrim($profile->service, '_');
        $proto = ltrim($profile->proto, '_');

        return sprintf('_%s._%s.%s', $service, $proto, $label);
    }

    public static function resolve(string $name, ZoneResolver $resolver): ResolvedZoneName
    {
        return $resolver->resolve($name);
    }

    public static function normalizeName(string $name, string $baseDomain): string
    {
        $name = trim($name);
        if (str_ends_with(strtolower($name), '.' . strtolower($baseDomain))) {
            return rtrim($name, '.');
        }

        if (!str_contains($name, '.')) {
            return $name . '.' . $baseDomain;
        }

        if (!self::looksLikeExternalFqdn($name, $baseDomain)) {
            return rtrim($name, '.') . '.' . $baseDomain;
        }

        return rtrim($name, '.');
    }

    public static function relativeLabel(string $fqdn, string $zoneName): string
    {
        $lowerFqdn = strtolower($fqdn);
        $lowerZone = strtolower(rtrim($zoneName, '.'));

        if ($lowerFqdn === $lowerZone) {
            return '@';
        }

        $suffix = '.' . $lowerZone;
        if (str_ends_with($lowerFqdn, $suffix)) {
            return substr($fqdn, 0, -strlen($suffix));
        }

        return $fqdn;
    }

    private static function looksLikeExternalFqdn(string $name, string $baseDomain): bool
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

        return $lowerName !== $lowerBase && !str_ends_with($lowerName, '.' . $lowerBase);
    }
}
