<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

class MinecraftToolsService
{
    protected array $api;

    public function __construct()
    {
        $this->api = config('minecraft-tools.api', []);
    }

    public function spigotPlugin(string $id): ?array
    {
        return Cache::remember("mct:spigot:{$id}", 3600, function () use ($id) {
            $url = ($this->api['spigot']['base_url'] ?? 'https://api.spiget.org/v2') . '/resources/' . $id;
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? $response->json() : null;
        });
    }

    public function spigotSearch(string $query, int $size = 20): array
    {
        $key = 'mct:spigot:search:' . md5($query . $size);

        return Cache::remember($key, 1800, function () use ($query, $size) {
            $url = ($this->api['spigot']['base_url'] ?? 'https://api.spiget.org/v2') . '/search/resources/' . urlencode($query);
            $response = Http::timeout(10)->get($url, ['size' => $size]);

            return $response->successful() ? $response->json() : [];
        });
    }

    public function modrinthProject(string $id): ?array
    {
        return Cache::remember("mct:modrinth:{$id}", 3600, function () use ($id) {
            $url = ($this->api['modrinth']['base_url'] ?? 'https://api.modrinth.com/v2') . '/project/' . $id;
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? $response->json() : null;
        });
    }

    public function modrinthSearch(string $query, array $filters = []): array
    {
        $key = 'mct:modrinth:search:' . md5($query . serialize($filters));

        return Cache::remember($key, 1800, function () use ($query, $filters) {
            $url = ($this->api['modrinth']['base_url'] ?? 'https://api.modrinth.com/v2') . '/search';
            $params = array_merge(['query' => $query], $filters);
            $response = Http::timeout(10)->get($url, $params);

            return $response->successful() ? $response->json() : ['hits' => []];
        });
    }

    public function modrinthVersions(string $projectId): array
    {
        $key = 'mct:modrinth:versions:' . md5($projectId);

        return Cache::remember($key, 1800, function () use ($projectId) {
            $url = ($this->api['modrinth']['base_url'] ?? 'https://api.modrinth.com/v2') . '/project/' . $projectId . '/version';
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? $response->json() : [];
        });
    }

    public function paperVersions(): array
    {
        return Cache::remember('mct:paper:versions', 3600, function () {
            $url = ($this->api['paper']['base_url'] ?? 'https://api.papermc.io/v2') . '/projects/paper';
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? ($response->json()['versions'] ?? []) : [];
        });
    }

    public function paperBuilds(string $version): array
    {
        return Cache::remember("mct:paper:builds:{$version}", 1800, function () use ($version) {
            $url = ($this->api['paper']['base_url'] ?? 'https://api.papermc.io/v2') . '/projects/paper/versions/' . $version . '/builds';
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? ($response->json()['builds'] ?? []) : [];
        });
    }

    public function fabricVersions(): array
    {
        return Cache::remember('mct:fabric:versions', 3600, function () {
            $url = ($this->api['fabric']['base_url'] ?? 'https://meta.fabricmc.net') . '/v2/versions/game';
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? $response->json() : [];
        });
    }

    public function fabricLoaders(): array
    {
        return Cache::remember('mct:fabric:loaders', 3600, function () {
            $url = ($this->api['fabric']['base_url'] ?? 'https://meta.fabricmc.net') . '/v2/versions/loader';
            $response = Http::timeout(10)->get($url);

            return $response->successful() ? $response->json() : [];
        });
    }

    public function generateIcon(string $text, string $background, string $fontColor, int $fontSize): ?string
    {
        if (!function_exists('imagecreatetruecolor')) {
            return null;
        }

        $width = 64;
        $height = 64;

        $image = imagecreatetruecolor($width, $height);

        $bg = hexdec(ltrim($background, '#'));
        $r = ($bg >> 16) & 0xFF;
        $g = ($bg >> 8) & 0xFF;
        $b = $bg & 0xFF;
        $bgColor = imagecolorallocate($image, $r, $g, $b);

        $fgHex = hexdec(ltrim($fontColor, '#'));
        $fg = imagecolorallocate($image, ($fgHex >> 16) & 0xFF, ($fgHex >> 8) & 0xFF, $fgHex & 0xFF);

        imagefill($image, 0, 0, $bgColor);

        $bbox = imagettfbbox($fontSize, 0, base_path('resources/fonts/DejaVuSans-Bold.ttf'), $text);
        if ($bbox !== false) {
            $textWidth = $bbox[2] - $bbox[0];
            $textHeight = $bbox[1] - $bbox[7];
            $x = ($width - $textWidth) / 2;
            $y = ($height + $textHeight) / 2;
            imagettftext($image, $fontSize, 0, $x, $y, $fg, base_path('resources/fonts/DejaVuSans-Bold.ttf'), $text);
        }

        ob_start();
        imagepng($image);
        $png = ob_get_clean();
        imagedestroy($image);

        return 'data:image/png;base64,' . base64_encode($png);
    }
}