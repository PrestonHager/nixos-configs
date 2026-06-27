<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

/**
 * Homelab defaults for global extension settings (Admin → Extensions → DNS Records).
 */
final class ExtensionDefaults
{
    /**
     * @return list<array<string, mixed>>
     */
    public static function srvProfiles(): array
    {
        return [
            [
                'id' => 'minecraft-java',
                'preset' => 'minecraft-java',
                'label' => 'Minecraft Java',
                'auto_provision' => true,
            ],
            [
                'id' => 'minecraft-bedrock',
                'preset' => 'minecraft-bedrock',
                'label' => 'Minecraft Bedrock',
                'auto_provision' => false,
            ],
            [
                'id' => 'factorio',
                'preset' => 'factorio',
                'label' => 'Factorio',
                'auto_provision' => true,
            ],
            [
                'id' => 'terraria',
                'preset' => 'terraria',
                'label' => 'Terraria',
                'auto_provision' => false,
            ],
            [
                'id' => 'valheim',
                'preset' => 'valheim',
                'label' => 'Valheim',
                'auto_provision' => false,
            ],
            [
                'id' => 'rust',
                'preset' => 'rust',
                'label' => 'Rust',
                'auto_provision' => false,
            ],
            [
                'id' => 'generic-tcp',
                'label' => 'Generic TCP',
                'service' => '_game',
                'proto' => '_tcp',
                'priority' => 0,
                'weight' => 5,
                'auto_provision' => false,
            ],
            [
                'id' => 'generic-udp',
                'label' => 'Generic UDP',
                'service' => '_game',
                'proto' => '_udp',
                'priority' => 0,
                'weight' => 5,
                'auto_provision' => false,
            ],
        ];
    }

    /**
     * Additional primary domains beyond the implicit default (base_domain + zone_id).
     *
     * @return list<array<string, mixed>>
     */
    public static function primaryDomains(): array
    {
        return [];
    }
}
