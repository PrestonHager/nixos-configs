<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;

class NodeIpResolver
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
    ) {
    }

    public function resolve(Server $server): string
    {
        $node = $server->node;
        if (is_null($node)) {
            throw new PluginException('Server has no associated node.');
        }

        $map = $this->config->nodeIpMap();
        $nodeId = (string) $node->id;
        if (isset($map[$nodeId])) {
            return $map[$nodeId];
        }

        $fqdn = strtolower((string) $node->fqdn);
        $name = strtolower((string) $node->name);
        if (str_contains($fqdn, 'crux') || $name === 'crux') {
            return $map['default_crux'] ?? '192.168.5.6';
        }
        if (str_contains($fqdn, 'nova') || $name === 'nova') {
            return $map['default_nova'] ?? '192.168.5.7';
        }

        foreach ($map as $key => $ip) {
            if (str_contains($key, 'default_')) {
                continue;
            }
        }

        throw new PluginException(sprintf('No LAN IP mapping configured for node "%s" (ID %d).', $node->name, $node->id));
    }
}
