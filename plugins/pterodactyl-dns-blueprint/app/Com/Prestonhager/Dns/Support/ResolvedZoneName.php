<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

final readonly class ResolvedZoneName
{
    public function __construct(
        public string $fqdn,
        public string $relativeLabel,
        public string $zoneId,
        public string $zoneName,
        public bool $inDefaultZone,
    ) {
    }
}
