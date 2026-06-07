<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Listeners;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs\DeleteDnsRecordsJob;
use Pterodactyl\Events\Server\Deleting;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class OnServerDeleting
{
    public function handle(PluginContext $context, Deleting $event): void
    {
        DeleteDnsRecordsJob::dispatch($event->server->id);
    }
}
