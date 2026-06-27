<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;

class MappingState
{
    private const KEY = 'mappings';

    public function __construct(
        private readonly PluginContext $context,
    ) {
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function all(int $serverId): array
    {
        $value = $this->context->data()->get('server', $serverId, self::KEY, []);

        return is_array($value) ? array_values($value) : [];
    }

    /**
     * @param array<string, mixed> $mapping
     */
    public function add(int $serverId, array $mapping): void
    {
        $mappings = $this->all($serverId);
        $mappings[] = $mapping;
        $this->context->data()->set('server', $serverId, self::KEY, $mappings);
    }

    /**
     * @param array<string, mixed> $mapping
     */
    public function update(int $serverId, string $mappingId, array $mapping): void
    {
        $mappings = [];
        foreach ($this->all($serverId) as $existing) {
            if (($existing['id'] ?? '') === $mappingId) {
                $mappings[] = array_merge($existing, $mapping);
            } else {
                $mappings[] = $existing;
            }
        }
        $this->context->data()->set('server', $serverId, self::KEY, $mappings);
    }

    public function remove(int $serverId, string $mappingId): ?array
    {
        $removed = null;
        $mappings = [];
        foreach ($this->all($serverId) as $existing) {
            if (($existing['id'] ?? '') === $mappingId) {
                $removed = $existing;
            } else {
                $mappings[] = $existing;
            }
        }
        $this->context->data()->set('server', $serverId, self::KEY, $mappings);

        return $removed;
    }

    public function clear(int $serverId): void
    {
        $this->context->data()->delete('server', $serverId, self::KEY);
    }
}
