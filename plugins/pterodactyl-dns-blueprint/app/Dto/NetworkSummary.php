<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto;

final readonly class NetworkSummary
{
    /**
     * @param AllocationSummary[] $allocations
     */
    public function __construct(
        public ServerSummary $server,
        public array $allocations,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'server' => $this->server->toArray(),
            'allocations' => array_map(fn (AllocationSummary $a) => $a->toArray(), $this->allocations),
        ];
    }
}
