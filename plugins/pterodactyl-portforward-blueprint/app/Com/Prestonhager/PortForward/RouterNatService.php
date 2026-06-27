<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward;

use Illuminate\Support\Str;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Cisco\NatRule;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Ssh\SshClient;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\AuditLog;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\MappingState;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\NodeIpResolver;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\PortValidator;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;

class RouterNatService
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
        private readonly PortValidator $validator,
        private readonly NodeIpResolver $nodeIpResolver,
        private readonly MappingState $state,
        private readonly SshClient $ssh,
        private readonly AuditLog $audit,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function createMapping(
        int $serverId,
        string $protocol,
        int $externalPort,
        ?int $internalPort = null,
    ): array {
        if (!$this->config->enabled()) {
            throw new PluginException('Port Forward extension is disabled.');
        }

        $server = $this->context->findServer($serverId);
        $allocation = $this->context->primaryAllocation($server);
        $internalPort ??= $allocation?->port;
        if (is_null($internalPort)) {
            throw new PluginException('No internal port specified and server has no primary allocation.');
        }

        if (count($this->state->all($serverId)) >= $this->config->maxMappingsPerServer()) {
            throw new PluginException('Maximum mappings per server reached.');
        }

        $protocol = strtolower($protocol);
        $this->validator->validate($externalPort, $protocol);
        $this->validator->validate($internalPort, $protocol);

        $insideIp = $this->nodeIpResolver->resolve($server);
        $rule = new NatRule($protocol, $insideIp, $internalPort, $externalPort, $this->config->wanInterface());
        $commands = [
            'configure terminal',
            $rule->addCommand(),
            'end',
        ];

        $result = $this->ssh->exec($commands);
        $success = $result['exitCode'] === 0;
        $this->audit->log(
            $this->config->dryRun() ? 'dry_run' : 'apply',
            $commands,
            $success,
            $result['stdout'],
            $success ? null : ($result['stderr'] ?: 'SSH command failed'),
            $serverId,
        );

        if (!$success) {
            throw new PluginException('Failed to apply NAT rule on router.');
        }

        $mapping = [
            'id' => (string) Str::uuid(),
            'protocol' => $protocol,
            'external_port' => $externalPort,
            'internal_port' => $internalPort,
            'inside_ip' => $insideIp,
            'ios_line' => $rule->addCommand(),
            'status' => $this->config->dryRun() ? 'dry_run' : 'active',
            'created_at' => now()->toIso8601String(),
        ];
        $this->state->add($serverId, $mapping);

        return $mapping;
    }

    public function removeMapping(int $serverId, string $mappingId): void
    {
        $existing = $this->state->remove($serverId, $mappingId);
        if (is_null($existing)) {
            throw new PluginException('Mapping not found.');
        }

        $rule = new NatRule(
            (string) $existing['protocol'],
            (string) $existing['inside_ip'],
            (int) $existing['internal_port'],
            (int) $existing['external_port'],
            $this->config->wanInterface(),
        );

        $commands = [
            'configure terminal',
            $rule->removeCommand(),
            'end',
        ];

        $result = $this->ssh->exec($commands);
        $success = $result['exitCode'] === 0;
        $this->audit->log(
            $this->config->dryRun() ? 'dry_run' : 'remove',
            $commands,
            $success,
            $result['stdout'],
            $success ? null : ($result['stderr'] ?: 'SSH remove failed'),
            $serverId,
        );

        if (!$success) {
            throw new PluginException('Failed to remove NAT rule on router.');
        }
    }

    public function removeAllForServer(int $serverId): void
    {
        foreach ($this->state->all($serverId) as $mapping) {
            try {
                $this->removeMapping($serverId, (string) $mapping['id']);
            } catch (PluginException) {
            }
        }
        $this->state->clear($serverId);
    }

    /**
     * @return array<string, mixed>
     */
    public function testConnection(): array
    {
        $result = $this->ssh->testConnection();
        $success = $result['exitCode'] === 0;
        $this->audit->log('test_connection', ['show ip interface brief'], $success, $result['stdout'], $success ? null : $result['stderr']);

        return [
            'success' => $success,
            'stdout' => $result['stdout'],
            'stderr' => $result['stderr'],
            'dry_run' => $this->config->dryRun(),
        ];
    }

    public function forwardPrimaryAllocation(int $serverId): ?array
    {
        $server = $this->context->findServer($serverId);
        $allocation = $this->context->primaryAllocation($server);
        if (is_null($allocation)) {
            return null;
        }

        return $this->createMapping($serverId, 'tcp', $allocation->port, $allocation->port);
    }

    public function forwardAllocation(int $serverId, int $allocationId): array
    {
        $server = $this->context->findServer($serverId);
        $allocation = $server->allocations->firstWhere('id', $allocationId);
        if (is_null($allocation)) {
            throw new PluginException('Allocation not found for this server.');
        }

        return $this->createMapping($serverId, 'tcp', $allocation->port, $allocation->port);
    }
}
