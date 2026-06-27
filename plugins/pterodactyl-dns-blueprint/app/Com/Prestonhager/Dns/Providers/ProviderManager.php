<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\AuditLog;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class ProviderManager
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly CloudflareProvider $cloudflare,
        private readonly TechnitiumProvider $technitium,
        private readonly AuditLog $audit,
    ) {
    }

    /**
     * @return DnsProviderInterface[]
     */
    public function providersFor(?string $override = null): array
    {
        $mode = $override ?? $this->config->dnsProviderMode();
        $providers = [];

        if ($mode === 'cloudflare' || $mode === 'both' || $mode === 'inherit') {
            if ($this->config->hasCloudflare()) {
                $providers[] = $this->cloudflare;
            }
        }

        if ($mode === 'technitium' || $mode === 'both') {
            if ($this->config->hasTechnitium()) {
                $providers[] = $this->technitium;
            }
        }

        if ($providers === [] && $mode === 'inherit') {
            if ($this->config->hasCloudflare()) {
                $providers[] = $this->cloudflare;
            }
        }

        return $providers;
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<int, array<string, mixed>>
     */
    public function createRecord(array $payload, string $zoneId, ?string $providerOverride = null, ?int $serverId = null): array
    {
        $records = [];
        foreach ($this->providersFor($providerOverride) as $provider) {
            $effectiveZone = $provider->name() === 'technitium'
                ? $this->config->technitiumDefaultZone()
                : $zoneId;

            if ($this->config->dryRunEnabled()) {
                $this->audit->log('dry_run', $provider->name(), (string) ($payload['name'] ?? ''), [
                    'action' => 'create',
                    'payload' => $this->redact($payload),
                    'zone' => $effectiveZone,
                ], $serverId);
                $records[] = array_merge($payload, [
                    'provider' => $provider->name(),
                    'record_id' => 'dry-run-' . uniqid(),
                    'cloudflare_id' => 'dry-run-' . uniqid(),
                    'zone_id' => $effectiveZone,
                ]);
                continue;
            }

            try {
                $record = $provider->createRecord($payload, $effectiveZone);
                $this->audit->log('create', $provider->name(), (string) ($record['name'] ?? ''), [
                    'type' => $record['type'] ?? null,
                    'zone' => $effectiveZone,
                ], $serverId);
                $records[] = $record;
            } catch (PluginException $e) {
                $this->audit->log('error', $provider->name(), (string) ($payload['name'] ?? ''), [
                    'action' => 'create',
                    'message' => $e->getMessage(),
                ], $serverId);
                throw $e;
            }
        }

        return $records;
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<int, array<string, mixed>>
     */
    public function updateRecord(string $recordId, array $payload, string $zoneId, array $existing, ?int $serverId = null): array
    {
        $providerName = (string) ($existing['provider'] ?? 'cloudflare');
        $provider = $this->resolveProvider($providerName);
        $effectiveZone = $provider->name() === 'technitium'
            ? $this->config->technitiumDefaultZone()
            : $zoneId;

        if ($this->config->dryRunEnabled()) {
            $this->audit->log('dry_run', $provider->name(), (string) ($payload['name'] ?? $existing['name'] ?? ''), [
                'action' => 'update',
                'record_id' => $recordId,
            ], $serverId);

            return [$existing];
        }

        $record = $provider->updateRecord($recordId, $payload, $effectiveZone);
        $this->audit->log('update', $provider->name(), (string) ($record['name'] ?? ''), [
            'record_id' => $recordId,
        ], $serverId);

        return [$record];
    }

    public function deleteRecord(array $existing, ?int $serverId = null): void
    {
        $providerName = (string) ($existing['provider'] ?? 'cloudflare');
        $provider = $this->resolveProvider($providerName);
        $recordId = (string) ($existing['record_id'] ?? $existing['cloudflare_id'] ?? '');
        $zoneId = (string) ($existing['zone_id'] ?? $this->config->zoneId());

        if ($recordId === '' || str_starts_with($recordId, 'dry-run-')) {
            return;
        }

        if ($this->config->dryRunEnabled()) {
            $this->audit->log('dry_run', $provider->name(), (string) ($existing['name'] ?? ''), [
                'action' => 'delete',
                'record_id' => $recordId,
            ], $serverId);

            return;
        }

        $provider->deleteRecord($recordId, $zoneId, $existing);
        $this->audit->log('delete', $provider->name(), (string) ($existing['name'] ?? ''), [
            'record_id' => $recordId,
        ], $serverId);
    }

    /**
     * @return array<string, mixed>
     */
    public function testConnection(string $providerName): array
    {
        $provider = $this->resolveProvider($providerName);
        $zones = $provider->listZones();

        return [
            'provider' => $provider->name(),
            'zone_count' => count($zones),
            'zones' => array_slice(array_map(
                fn (array $z) => $z['name'] ?? $z['zone'] ?? $z['id'] ?? 'unknown',
                $zones
            ), 0, 20),
        ];
    }

    private function resolveProvider(string $name): DnsProviderInterface
    {
        return match ($name) {
            'technitium' => $this->technitium,
            'cloudflare' => $this->cloudflare,
            default => throw new PluginException(sprintf('Unknown DNS provider "%s".', $name)),
        };
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    private function redact(array $payload): array
    {
        unset($payload['cloudflare_api_token'], $payload['technitium_api_token']);

        return $payload;
    }
}
