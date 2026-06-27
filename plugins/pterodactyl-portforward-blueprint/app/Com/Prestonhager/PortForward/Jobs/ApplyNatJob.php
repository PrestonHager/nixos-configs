<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Jobs;

use Illuminate\Foundation\Bus\Dispatchable;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Services;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContextFactory;

class ApplyNatJob
{
    use Dispatchable;

    public function __construct(
        public readonly int $serverId,
        public readonly string $protocol = 'tcp',
        public readonly ?int $externalPort = null,
        public readonly ?int $internalPort = null,
    ) {
    }

    public function handle(PluginContextFactory $contextFactory): void
    {
        $context = $contextFactory->make();
        $config = Services::config($context);

        if (!$config->enabled() || !$config->autoForwardOnInstall()) {
            return;
        }

        $service = Services::routerNat($context);
        $server = $context->findServer($this->serverId);
        $allocation = $context->primaryAllocation($server);
        if (is_null($allocation)) {
            return;
        }

        $external = $this->externalPort ?? $allocation->port;
        $internal = $this->internalPort ?? $allocation->port;
        $service->createMapping($this->serverId, $this->protocol, $external, $internal);
    }
}
