<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\AllocationSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\NetworkSummary;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto\ServerSummary;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Server;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionData;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionSetting;

class PluginContext
{
    public const IDENTIFIER = 'dnsrecords';
    public const LEGACY_PLUGIN_ID = 'com.prestonhager.dns';

    private ConfigAccessor $config;
    private DataAccessor $data;
    private ServerAccessor $servers;
    private HttpClientAccessor $http;
    private ActivityAccessor $activity;

    public function __construct()
    {
        $this->config = new ConfigAccessor();
        $this->data = new DataAccessor();
        $this->servers = new ServerAccessor();
        $this->http = new HttpClientAccessor();
        $this->activity = new ActivityAccessor();
    }

    public static function make(): self
    {
        return new self();
    }

    public function id(): string
    {
        return self::LEGACY_PLUGIN_ID;
    }

    public function config(): ConfigAccessor
    {
        return $this->config;
    }

    public function data(): DataAccessor
    {
        return $this->data;
    }

    public function servers(): ServerAccessor
    {
        return $this->servers;
    }

    public function http(): HttpClientAccessor
    {
        return $this->http;
    }

    public function activity(): ActivityAccessor
    {
        return $this->activity;
    }
}

class ConfigAccessor
{
    public function get(string $key, mixed $default = null): mixed
    {
        $row = DnsExtensionSetting::query()->where('key', $key)->first();
        if (is_null($row)) {
            return $default;
        }

        return $row->value ?? $default;
    }

    public function set(string $key, mixed $value): void
    {
        DnsExtensionSetting::query()->updateOrCreate(
            ['key' => $key],
            ['value' => $value]
        );
    }

    /**
     * @return array<string, mixed>
     */
    public function all(): array
    {
        $settings = [];
        foreach (DnsExtensionSetting::query()->get() as $row) {
            $settings[$row->key] = $row->value;
        }

        return $settings;
    }

    /**
     * @param array<string, mixed> $values
     */
    public function replace(array $values): void
    {
        foreach ($values as $key => $value) {
            $this->set((string) $key, $value);
        }
    }
}

class DataAccessor
{
    public function get(string $scope, int $subjectId, string $key, mixed $default = null): mixed
    {
        $row = DnsExtensionData::query()
            ->where('scope', $scope)
            ->where('subject_id', $subjectId)
            ->where('key', $key)
            ->first();

        if (is_null($row)) {
            return $default;
        }

        return $row->value ?? $default;
    }

    public function set(string $scope, int $subjectId, string $key, mixed $value): void
    {
        DnsExtensionData::query()->updateOrCreate(
            [
                'scope' => $scope,
                'subject_id' => $subjectId,
                'key' => $key,
            ],
            ['value' => $value]
        );
    }

    public function delete(string $scope, int $subjectId, string $key): void
    {
        DnsExtensionData::query()
            ->where('scope', $scope)
            ->where('subject_id', $subjectId)
            ->where('key', $key)
            ->delete();
    }
}

class ServerAccessor
{
    public function find(int $serverId): ServerSummary
    {
        $server = Server::query()->find($serverId);
        if (is_null($server)) {
            throw new PluginException(sprintf('Server with ID %d was not found.', $serverId));
        }

        return self::serverSummaryFromModel($server);
    }

    public function getNetworkSummary(int $serverId): NetworkSummary
    {
        $server = $this->find($serverId);
        if (is_null($server)) {
            throw new PluginException(sprintf('Server %d was not found.', $serverId));
        }

        $summary = new ServerSummary(
            id: $server->id,
            uuid: $server->uuid,
            name: $server->name,
            status: $server->status,
            nodeId: $server->node_id,
            ownerId: $server->owner_id,
            allocationId: $server->allocation_id,
            externalId: $server->external_id,
        );

        $allocations = $server->allocations->map(static function (Allocation $allocation) use ($server) {
            return new AllocationSummary(
                id: $allocation->id,
                ip: $allocation->ip,
                port: $allocation->port,
                isPrimary: $allocation->id === $server->allocation_id,
                notes: $allocation->notes,
                ipAlias: $allocation->alias,
            );
        })->all();

        return new NetworkSummary($summary, $allocations);
    }

    public static function serverSummaryFromModel(Server $server): ServerSummary
    {
        return new ServerSummary(
            id: $server->id,
            uuid: $server->uuid,
            name: $server->name,
            status: $server->status,
            nodeId: $server->node_id,
            ownerId: $server->owner_id,
            allocationId: $server->allocation_id,
            externalId: $server->external_id,
        );
    }
}

class HttpClientAccessor
{
    /**
     * @param array<string, mixed> $options
     * @return array{status: int, body: string}
     */
    public function request(string $method, string $url, array $options = []): array
    {
        $headers = $options['headers'] ?? [];
        $pending = Http::withHeaders($headers)->timeout(30);

        if (isset($options['json'])) {
            $response = $pending->send($method, $url, ['json' => $options['json']]);
        } else {
            $response = $pending->send($method, $url);
        }

        return [
            'status' => $response->status(),
            'body' => $response->body(),
        ];
    }
}

class ActivityAccessor
{
    /**
     * @param array<string, mixed> $metadata
     */
    public function log(string $event, array $metadata = []): void
    {
        if (!DB::getSchemaBuilder()->hasTable('plugin_activity_logs')) {
            return;
        }

        DB::table('plugin_activity_logs')->insert([
            'plugin_id' => PluginContext::LEGACY_PLUGIN_ID,
            'event' => $event,
            'subject_type' => isset($metadata['server_id']) ? 'server' : null,
            'subject_id' => $metadata['server_id'] ?? null,
            'metadata' => json_encode($metadata),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }
}
