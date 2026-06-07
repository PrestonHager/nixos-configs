<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Listeners;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs\ProvisionSrvProfilesJob;
use Pterodactyl\Events\Server\Installed;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class OnServerInstalled
{
    public function handle(PluginContext $context, Installed $event): void
    {
        ProvisionSrvProfilesJob::dispatch($event->server->id);
    }
}
