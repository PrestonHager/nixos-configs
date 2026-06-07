<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;
use Illuminate\Foundation\Bus\Dispatchable;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContextFactory;

class ProvisionSrvProfilesJob
{
    use Dispatchable;

    public function __construct(
        public readonly int $serverId,
    ) {
    }

    public function handle(PluginContextFactory $contextFactory): void
    {
        $context = $contextFactory->make();

        if (!Services::config($context)->autoProvisionEnabled()) {
            return;
        }

        Services::srvProvisioner($context)->provision($this->serverId);
    }
}
