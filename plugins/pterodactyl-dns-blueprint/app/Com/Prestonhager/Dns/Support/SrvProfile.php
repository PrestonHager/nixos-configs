<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

final readonly class SrvProfile
{
    public function __construct(
        public string $id,
        public string $label,
        public string $service,
        public string $proto,
        public ?int $port = null,
        public int $priority = 0,
        public int $weight = 5,
        public bool $autoProvision = false,
        public ?string $targetProvider = null,
    ) {
    }

    /**
     * @param array<string, mixed> $entry
     */
    public static function fromConfigEntry(array $entry): ?self
    {
        $id = isset($entry['id']) ? (string) $entry['id'] : '';
        if ($id === '') {
            return null;
        }

        if (isset($entry['preset']) && is_string($entry['preset'])) {
            $preset = SrvPresets::get($entry['preset']);
            if (is_null($preset)) {
                throw new PluginException(sprintf('Unknown SRV preset "%s" in profile "%s".', $entry['preset'], $id));
            }

            return new self(
                id: $id,
                label: isset($entry['label']) ? (string) $entry['label'] : $preset->label,
                service: $preset->service,
                proto: $preset->proto,
                port: self::optionalPort($entry['port'] ?? $preset->port),
                priority: self::optionalInt($entry['priority'] ?? $preset->priority, $preset->priority),
                weight: self::optionalInt($entry['weight'] ?? $preset->weight, $preset->weight),
                autoProvision: self::optionalBool($entry['auto_provision'] ?? $preset->autoProvision, $preset->autoProvision),
                targetProvider: self::optionalProvider($entry['target_provider'] ?? null),
            );
        }

        $service = isset($entry['service']) ? (string) $entry['service'] : '';
        $proto = isset($entry['proto']) ? (string) $entry['proto'] : '';
        if ($service === '' || $proto === '') {
            throw new PluginException(sprintf('SRV profile "%s" requires service and proto, or a preset.', $id));
        }

        self::assertProto($proto);

        return new self(
            id: $id,
            label: isset($entry['label']) ? (string) $entry['label'] : $id,
            service: self::normalizeService($service),
            proto: self::normalizeProto($proto),
            port: self::optionalPort($entry['port'] ?? null),
            priority: self::optionalInt($entry['priority'] ?? null, 0),
            weight: self::optionalInt($entry['weight'] ?? null, 5),
            autoProvision: self::optionalBool($entry['auto_provision'] ?? null, false),
            targetProvider: self::optionalProvider($entry['target_provider'] ?? null),
        );
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'label' => $this->label,
            'service' => $this->service,
            'proto' => $this->proto,
            'port' => $this->port,
            'priority' => $this->priority,
            'weight' => $this->weight,
            'auto_provision' => $this->autoProvision,
            'target_provider' => $this->targetProvider,
        ];
    }

    private static function normalizeService(string $service): string
    {
        return str_starts_with($service, '_') ? $service : '_' . $service;
    }

    private static function normalizeProto(string $proto): string
    {
        self::assertProto($proto);

        return str_starts_with($proto, '_') ? $proto : '_' . $proto;
    }

    private static function assertProto(string $proto): void
    {
        $normalized = str_starts_with($proto, '_') ? $proto : '_' . $proto;
        if (!in_array($normalized, ['_tcp', '_udp'], true)) {
            throw new PluginException(sprintf('SRV proto must be _tcp or _udp, got "%s".', $proto));
        }
    }

    private static function optionalPort(mixed $value): ?int
    {
        if ($value === null || $value === '') {
            return null;
        }

        return (int) $value;
    }

    private static function optionalInt(mixed $value, int $default): int
    {
        if ($value === null || $value === '') {
            return $default;
        }

        return (int) $value;
    }

    private static function optionalBool(mixed $value, bool $default): bool
    {
        if ($value === null) {
            return $default;
        }

        return filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) ?? (bool) $value;
    }

    private static function optionalProvider(mixed $value): ?string
    {
        if (!is_string($value) || $value === '' || $value === 'inherit') {
            return null;
        }

        $allowed = ['cloudflare', 'technitium', 'both'];
        if (!in_array($value, $allowed, true)) {
            return null;
        }

        return $value;
    }
}
