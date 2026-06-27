<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;
use Pterodactyl\Models\Server;

class ServerForwardOverview
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly MappingState $state,
        private readonly NodeIpResolver $nodeIpResolver,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function build(int $serverId): array
    {
        $server = $this->context->findServer($serverId);
        $nodeIp = $this->resolveNodeIp($server);
        $mappings = $this->state->all($serverId);
        $allocations = $this->buildAllocations($server, $nodeIp, $mappings);

        $pending = array_values(array_filter(
            $allocations,
            static fn (array $row): bool => ($row['forward_status'] ?? 'pending') === 'pending',
        ));

        $active = array_values(array_filter(
            $mappings,
            static fn (array $row): bool => in_array($row['status'] ?? '', ['active', 'dry_run'], true),
        ));

        return [
            'server_id' => $serverId,
            'node' => [
                'id' => $server->node_id,
                'name' => $server->node->name ?? null,
                'lan_ip' => $nodeIp,
            ],
            'allocations' => $allocations,
            'pending' => $pending,
            'mappings' => $mappings,
            'active_mappings' => $active,
        ];
    }

    private function resolveNodeIp(Server $server): ?string
    {
        try {
            return $this->nodeIpResolver->resolve($server);
        } catch (PluginException) {
            return null;
        }
    }

    /**
     * @param array<int, array<string, mixed>> $mappings
     * @return array<int, array<string, mixed>>
     */
    private function buildAllocations(Server $server, ?string $nodeIp, array $mappings): array
    {
        $rows = [];

        foreach ($server->allocations as $allocation) {
            $mapping = $this->findMappingForPort($mappings, (int) $allocation->port, $nodeIp);
            $forwardStatus = 'pending';
            if (!is_null($mapping)) {
                $forwardStatus = (string) ($mapping['status'] ?? 'active');
            }

            $rows[] = [
                'allocation_id' => $allocation->id,
                'port' => (int) $allocation->port,
                'ip' => (string) $allocation->ip,
                'is_primary' => $allocation->id === $server->allocation_id,
                'target_ip' => $nodeIp,
                'suggested_external_port' => (int) $allocation->port,
                'suggested_internal_port' => (int) $allocation->port,
                'protocol' => 'tcp',
                'forward_status' => $forwardStatus,
                'mapping' => $mapping,
            ];
        }

        usort($rows, static function (array $a, array $b): int {
            if ($a['is_primary'] !== $b['is_primary']) {
                return $a['is_primary'] ? -1 : 1;
            }

            return $a['port'] <=> $b['port'];
        });

        return $rows;
    }

    /**
     * @param array<int, array<string, mixed>> $mappings
     * @return array<string, mixed>|null
     */
    private function findMappingForPort(array $mappings, int $port, ?string $nodeIp): ?array
    {
        foreach ($mappings as $mapping) {
            if ((int) ($mapping['internal_port'] ?? 0) !== $port) {
                continue;
            }

            if (!is_null($nodeIp) && isset($mapping['inside_ip']) && (string) $mapping['inside_ip'] !== $nodeIp) {
                continue;
            }

            if (!in_array($mapping['status'] ?? '', ['active', 'dry_run'], true)) {
                continue;
            }

            return $mapping;
        }

        return null;
    }
}
