<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;
use Illuminate\Foundation\Bus\Dispatchable;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContextFactory;

class UpdateSrvOnAllocationJob
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

        if (!$config->updateOnAllocationChange()) {
            return;
        }

        Services::srvProvisioner($context)->provision($this->serverId);
    }
}
