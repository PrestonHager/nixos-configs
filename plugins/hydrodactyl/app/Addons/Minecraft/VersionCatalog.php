<?php

namespace Pterodactyl\Addons\Minecraft;

use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Cache;

/**
 * Works out which Minecraft server software an egg runs (from its startup
 * variables) and lists the versions/builds that software publishes.
 *
 * Version switching only edits those startup variables; the egg's install
 * script downloads the jar on reinstall, so nothing here touches the server
 * files directly.
 */
class VersionCatalog
{
    /**
     * Loader => [minecraft version variable, secondary (build/loader) variable].
     */
    private const LOADERS = [
        'fabric' => ['MC_VERSION', 'FABRIC_VERSION', 'LOADER_VERSION'],
        'neoforge' => ['MC_VERSION', 'NEOFORGE_VERSION'],
        'forge' => ['MC_VERSION', 'FORGE_VERSION'],
        'purpur' => ['MINECRAFT_VERSION', 'BUILD_NUMBER'],
        'paper' => ['MINECRAFT_VERSION', 'BUILD_NUMBER'],
        'vanilla' => ['VANILLA_VERSION'],
    ];

    /**
     * @return array{loader: string|null, variables: array<string, array{value: string|null, editable: bool, rules: string}>}
     */
    public function detect(Server $server): array
    {
        $vars = [];
        foreach ($server->variables()->get() as $variable) {
            $vars[$variable->env_variable] = [
                'value' => $variable->server_value ?? $variable->default_value,
                'editable' => (bool) $variable->user_editable,
                'rules' => (string) $variable->rules,
            ];
        }

        $egg = strtolower((string) $server->egg?->name);
        $loader = match (true) {
            isset($vars['FABRIC_VERSION']) => 'fabric',
            isset($vars['NEOFORGE_VERSION']) => 'neoforge',
            isset($vars['FORGE_VERSION']) => 'forge',
            isset($vars['MINECRAFT_VERSION']) && str_contains($egg, 'purpur') => 'purpur',
            isset($vars['MINECRAFT_VERSION']) && str_contains($egg, 'paper') => 'paper',
            isset($vars['VANILLA_VERSION']) => 'vanilla',
            default => null,
        };

        $relevant = $loader ? array_intersect_key($vars, array_flip(self::LOADERS[$loader])) : [];

        return ['loader' => $loader, 'variables' => $relevant];
    }

    /**
     * Release versions (newest first) for the loader.
     *
     * @return string[]
     */
    public function versions(string $loader): array
    {
        return Cache::remember("homelab:mc:versions:$loader", 3600, function () use ($loader) {
            return match ($loader) {
                'paper' => $this->paperVersions(),
                'purpur' => array_reverse((array) ($this->json('https://api.purpurmc.org/v2/purpur')['versions'] ?? [])),
                'fabric' => collect($this->json('https://meta.fabricmc.net/v2/versions/game'))
                    ->where('stable', true)->pluck('version')->values()->all(),
                'neoforge' => $this->neoforgeMinecraftVersions(),
                'forge', 'vanilla' => collect($this->json('https://piston-meta.mojang.com/mc/game/version_manifest_v2.json')['versions'] ?? [])
                    ->where('type', 'release')->pluck('id')->values()->all(),
                default => [],
            };
        });
    }

    /**
     * Builds (or loader versions) for a Minecraft version, newest first.
     *
     * @return string[]
     */
    public function builds(string $loader, string $version): array
    {
        return Cache::remember("homelab:mc:builds:$loader:$version", 1800, function () use ($loader, $version) {
            return match ($loader) {
                'paper' => collect($this->json("https://fill.papermc.io/v3/projects/paper/versions/$version/builds"))
                    ->pluck('id')->map(fn ($id) => (string) $id)->values()->all(),
                'purpur' => array_reverse((array) ($this->json("https://api.purpurmc.org/v2/purpur/$version")['builds']['all'] ?? [])),
                'fabric' => collect($this->json('https://meta.fabricmc.net/v2/versions/loader'))
                    ->where('stable', true)->pluck('version')->values()->all(),
                'neoforge' => $this->neoforgeBuilds($version),
                default => [],
            };
        });
    }

    private function paperVersions(): array
    {
        $groups = (array) ($this->json('https://fill.papermc.io/v3/projects/paper')['versions'] ?? []);

        return collect($groups)->flatten()
            ->reject(fn ($v) => preg_match('/-(rc|pre)/i', (string) $v))
            ->values()->all();
    }

    private function neoforgeMinecraftVersions(): array
    {
        return collect($this->neoforgeReleases())
            ->map(fn (string $v) => self::neoforgeToMinecraft($v))
            ->filter()->unique()->values()->all();
    }

    private function neoforgeBuilds(string $minecraft): array
    {
        return collect($this->neoforgeReleases())
            ->filter(fn (string $v) => self::neoforgeToMinecraft($v) === $minecraft)
            ->values()->all();
    }

    private function neoforgeReleases(): array
    {
        $versions = (array) ($this->json('https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge')['versions'] ?? []);

        return array_reverse(array_values(array_filter($versions, fn ($v) => !str_contains((string) $v, 'beta'))));
    }

    /**
     * "21.1.250" targets 1.21.1 (pre-2026 numbering drops the leading "1.");
     * "26.3.0.99" targets 26.3 and "26.3.1.4" targets 26.3.1.
     */
    public static function neoforgeToMinecraft(string $neoforge): ?string
    {
        if (!preg_match('/^(\d+)\.(\d+)\.(\d+)/', $neoforge, $m)) {
            return null;
        }

        if ((int) $m[1] < 26) {
            return $m[2] === '0' ? "1.{$m[1]}" : "1.{$m[1]}.{$m[2]}";
        }

        return $m[3] === '0' ? "{$m[1]}.{$m[2]}" : "{$m[1]}.{$m[2]}.{$m[3]}";
    }

    private function json(string $url): array
    {
        $response = Http::timeout(10)->acceptJson()->get($url);

        return $response->successful() ? (array) $response->json() : [];
    }
}
