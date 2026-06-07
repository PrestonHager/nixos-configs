<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto;

final readonly class AllocationSummary
{
    public function __construct(
        public int $id,
        public string $ip,
        public int $port,
        public bool $isPrimary,
        public ?string $notes,
        public ?string $ipAlias = null,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'ip' => $this->ip,
            'port' => $this->port,
            'is_primary' => $this->isPrimary,
            'notes' => $this->notes,
            'ip_alias' => $this->ipAlias,
        ];
    }
}
