<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Cisco;

final readonly class NatRule
{
    public function __construct(
        public string $protocol,
        public string $insideIp,
        public int $insidePort,
        public int $outsidePort,
        public string $wanInterface,
    ) {
    }

    public function addCommand(): string
    {
        return sprintf(
            'ip nat inside source static %s %s %d interface %s %d',
            $this->protocol,
            $this->insideIp,
            $this->insidePort,
            $this->wanInterface,
            $this->outsidePort,
        );
    }

    public function removeCommand(): string
    {
        return 'no ' . $this->addCommand();
    }
}
