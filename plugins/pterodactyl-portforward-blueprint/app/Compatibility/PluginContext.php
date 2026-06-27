<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Models\PortForwardData;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Models\PortForwardSetting;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;

class PluginContext
{
    public const IDENTIFIER = 'portforward';

    private ConfigAccessor $config;
    private DataAccessor $data;

    public function __construct()
    {
        $this->config = new ConfigAccessor();
        $this->data = new DataAccessor();
    }

    public static function make(): self
    {
        return new self();
    }

    public function config(): ConfigAccessor
    {
        return $this->config;
    }

    public function data(): DataAccessor
    {
        return $this->data;
    }

    public function findServer(int $serverId): Server
    {
        $server = Server::query()->with(['allocations', 'node'])->find($serverId);
        if (is_null($server)) {
            throw new PluginException(sprintf('Server with ID %d was not found.', $serverId));
        }

        return $server;
    }

    public function primaryAllocation(Server $server): ?Allocation
    {
        foreach ($server->allocations as $allocation) {
            if ($allocation->id === $server->allocation_id) {
                return $allocation;
            }
        }

        return null;
    }
}

class ConfigAccessor
{
    public function get(string $key, mixed $default = null): mixed
    {
        $row = PortForwardSetting::query()->where('key', $key)->first();

        return is_null($row) ? $default : ($row->value ?? $default);
    }

    public function set(string $key, mixed $value): void
    {
        PortForwardSetting::query()->updateOrCreate(['key' => $key], ['value' => $value]);
    }

    /**
     * @return array<string, mixed>
     */
    public function all(): array
    {
        $settings = [];
        foreach (PortForwardSetting::query()->get() as $row) {
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
        $row = PortForwardData::query()
            ->where('scope', $scope)
            ->where('subject_id', $subjectId)
            ->where('key', $key)
            ->first();

        return is_null($row) ? $default : ($row->value ?? $default);
    }

    public function set(string $scope, int $subjectId, string $key, mixed $value): void
    {
        PortForwardData::query()->updateOrCreate(
            ['scope' => $scope, 'subject_id' => $subjectId, 'key' => $key],
            ['value' => $value]
        );
    }

    public function delete(string $scope, int $subjectId, string $key): void
    {
        PortForwardData::query()
            ->where('scope', $scope)
            ->where('subject_id', $subjectId)
            ->where('key', $key)
            ->delete();
    }
}

class PluginContextFactory
{
    public function make(): PluginContext
    {
        return PluginContext::make();
    }
}
