<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class NodeTargetResolver
{
    public function __construct(
        private readonly Config $config,
    ) {
    }

    public function fqdnForServer(int $serverId): string
    {
        $server = Server::query()->with('node')->find($serverId);
        if (is_null($server) || is_null($server->node)) {
            throw new PluginException('Server has no associated node.');
        }

        return $this->fqdnForNode($server->node);
    }

    public function fqdnForNode(Node $node): string
    {
        $fqdn = strtolower(rtrim((string) $node->fqdn, '.'));
        if ($fqdn !== '') {
            return $fqdn;
        }

        $map = $this->config->nodeFqdnMap();
        $nodeId = (string) $node->id;
        if (isset($map[$nodeId]) && is_string($map[$nodeId]) && $map[$nodeId] !== '') {
            return strtolower(rtrim($map[$nodeId], '.'));
        }

        $name = strtolower((string) $node->name);
        $genericDefault = "default_{$name}";
        if (isset($map[$genericDefault]) && is_string($map[$genericDefault]) && $map[$genericDefault] !== '') {
            return strtolower(rtrim($map[$genericDefault], '.'));
        }
        if (str_contains($name, 'crux') || str_contains($name, 'nova')) {
            $key = str_contains($name, 'nova') ? 'default_nova' : 'default_crux';
            if (isset($map[$key]) && is_string($map[$key]) && $map[$key] !== '') {
                return strtolower(rtrim($map[$key], '.'));
            }
        }

        if (str_contains($name, 'crux')) {
            return 'crux.lc1.nm.us.prestonhager.com';
        }
        if (str_contains($name, 'nova')) {
            return 'nova.lc1.nm.us.prestonhager.com';
        }

        throw new PluginException(sprintf(
            'No node FQDN configured for node "%s" (ID %d). Set node FQDN in Pterodactyl or node_fqdn_map in extension settings.',
            $node->name,
            $node->id,
        ));
    }
}
