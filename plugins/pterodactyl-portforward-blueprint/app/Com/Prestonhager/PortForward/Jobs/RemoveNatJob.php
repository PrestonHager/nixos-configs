<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Jobs;

use Illuminate\Foundation\Bus\Dispatchable;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Services;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContextFactory;

class RemoveNatJob
{
    use Dispatchable;

    public function __construct(
        public readonly int $serverId,
    ) {
    }

    public function handle(PluginContextFactory $contextFactory): void
    {
        $context = $contextFactory->make();
        $config = Services::config($context);

        if (!$config->autoRemoveOnDelete()) {
            return;
        }

        Services::routerNat($context)->removeAllForServer($this->serverId);
    }
}
