<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Dto;

final readonly class ServerSummary
{
    public function __construct(
        public int $id,
        public string $uuid,
        public string $name,
        public ?string $status,
        public int $nodeId,
        public int $ownerId,
        public int $allocationId,
        public ?string $externalId,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'uuid' => $this->uuid,
            'name' => $this->name,
            'status' => $this->status,
            'node_id' => $this->nodeId,
            'owner_id' => $this->ownerId,
            'allocation_id' => $this->allocationId,
            'external_id' => $this->externalId,
        ];
    }
}
