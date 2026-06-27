<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;

class PortValidator
{
    public function __construct(
        private readonly Config $config,
    ) {
    }

    public function validate(int $port, string $protocol): void
    {
        $protocol = strtolower($protocol);
        if (!in_array($protocol, ['tcp', 'udp'], true)) {
            throw new PluginException('Protocol must be tcp or udp.');
        }

        if ($port < $this->config->allowedPortMin() || $port > $this->config->allowedPortMax()) {
            throw new PluginException(sprintf(
                'Port %d is outside the allowed range %d-%d.',
                $port,
                $this->config->allowedPortMin(),
                $this->config->allowedPortMax(),
            ));
        }

        if (in_array($port, $this->config->blockedPorts(), true)) {
            throw new PluginException(sprintf('Port %d is blocked by policy.', $port));
        }
    }
}
