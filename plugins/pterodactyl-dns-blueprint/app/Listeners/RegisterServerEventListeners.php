<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Listeners;

use Illuminate\Support\Facades\Event;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs\DeleteDnsRecordsJob;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs\ProvisionSrvProfilesJob;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs\UpdateSrvOnAllocationJob;
use Pterodactyl\Events\Server\Deleting;
use Pterodactyl\Events\Server\Installed;
use Pterodactyl\Events\Server\Updated;

class RegisterServerEventListeners
{
    public static function boot(): void
    {
        static $registered = false;
        if ($registered) {
            return;
        }
        $registered = true;

        Event::listen(Installed::class, function (Installed $event) {
            ProvisionSrvProfilesJob::dispatch($event->server->id);
        });

        Event::listen(Deleting::class, function (Deleting $event) {
            DeleteDnsRecordsJob::dispatch($event->server->id);
        });

        Event::listen(Updated::class, function (Updated $event) {
            if ($event->server->wasChanged('allocation_id')) {
                UpdateSrvOnAllocationJob::dispatch($event->server->id);
            }
        });
    }
}
