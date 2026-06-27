<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Listeners;

use Illuminate\Support\Facades\Event;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Jobs\ApplyNatJob;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Jobs\RemoveNatJob;
use Pterodactyl\Events\Server\Deleting;
use Pterodactyl\Events\Server\Installed;

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
            ApplyNatJob::dispatch($event->server->id);
        });

        Event::listen(Deleting::class, function (Deleting $event) {
            RemoveNatJob::dispatch($event->server->id);
        });
    }
}
