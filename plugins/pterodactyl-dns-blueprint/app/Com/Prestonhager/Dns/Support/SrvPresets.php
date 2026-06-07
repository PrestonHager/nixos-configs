<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

class SrvPresets
{
    /** @var array<string, SrvProfile> */
    private static array $presets = [];

    public static function get(string $id): ?SrvProfile
    {
        self::boot();

        return self::$presets[$id] ?? null;
    }

    /**
     * @return array<string, SrvProfile>
     */
    public static function all(): array
    {
        self::boot();

        return self::$presets;
    }

    private static function boot(): void
    {
        if (!empty(self::$presets)) {
            return;
        }

        $definitions = [
            'minecraft-java' => ['Minecraft Java', '_minecraft', '_tcp'],
            'minecraft-bedrock' => ['Minecraft Bedrock', '_minecraft', '_udp'],
            'factorio' => ['Factorio', '_factorio', '_udp'],
            'terraria' => ['Terraria', '_terraria', '_tcp'],
            'rust' => ['Rust', '_rust', '_tcp'],
            'valheim' => ['Valheim', '_valheim', '_udp'],
            'ark' => ['ARK', '_ark', '_udp'],
            'mumble' => ['Mumble', '_mumble', '_tcp'],
        ];

        foreach ($definitions as $id => [$label, $service, $proto]) {
            self::$presets[$id] = new SrvProfile(
                id: $id,
                label: $label,
                service: $service,
                proto: $proto,
                autoProvision: false,
            );
        }
    }
}
