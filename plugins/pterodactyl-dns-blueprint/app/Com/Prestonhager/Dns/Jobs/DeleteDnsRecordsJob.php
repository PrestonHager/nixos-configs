<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Jobs;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;
use Illuminate\Foundation\Bus\Dispatchable;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContextFactory;

class DeleteDnsRecordsJob
{
    use Dispatchable;

    public function __construct(
        public readonly int $serverId,
    ) {
    }

    public function handle(PluginContextFactory $contextFactory): void
    {
        $context = $contextFactory->make();
        Services::dns($context)->deleteAllForServer($this->serverId);

        $context->activity()->log('dns-records-deleted', [
            'server_id' => $this->serverId,
        ]);
    }
}
