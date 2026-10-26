<?php

namespace Pterodactyl\Addons\Minecraft;

use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Facades\Activity;
use Pterodactyl\Models\Permission;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Cache;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Addons\Minecraft\Models\ModpackConfig;
use Symfony\Component\HttpKernel\Exception\HttpException;

/**
 * Modrinth modpack (.mrpack) install/remove for /minecraft/modpacks.
 * Installation runs on the queue (InstallModpackJob) because a pack can be
 * hundreds of files; the UI polls installed() for progress.
 */
class ModpackController extends Controller
{
    private const API = 'https://api.modrinth.com/v2';

    public function __construct(private readonly VersionCatalog $catalog)
    {
    }

    public function search(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_MOD_DOWNLOAD);
        $query = (string) $request->query('query', '');
        $loader = $this->catalog->detect($server)['loader'];

        $facets = [['project_type:modpack'], ['server_side:required', 'server_side:optional']];
        if (in_array($loader, ['fabric', 'neoforge', 'forge'], true)) {
            $facets[] = ["categories:$loader"];
        }

        $result = Cache::remember('homelab:mc:modpacks:' . sha1($query . $loader . $request->query('offset', 0)), 900, fn () => Http::timeout(10)
            ->get(self::API . '/search', [
                'query' => $query,
                'facets' => json_encode($facets),
                'limit' => 20,
                'offset' => max(0, (int) $request->query('offset', 0)),
                'index' => $query === '' ? 'downloads' : 'relevance',
            ])->json() ?: []);

        return response()->json([
            'loader' => $loader,
            'total' => $result['total_hits'] ?? 0,
            'hits' => collect($result['hits'] ?? [])->map(fn ($h) => [
                'id' => $h['project_id'],
                'slug' => $h['slug'],
                'title' => $h['title'],
                'description' => $h['description'],
                'icon_url' => $h['icon_url'] ?? null,
                'downloads' => $h['downloads'] ?? 0,
                'versions' => $h['versions'] ?? [],
            ]),
        ]);
    }

    public function versions(Request $request, Server $server, string $project): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_MOD_DOWNLOAD);
        abort_unless(preg_match('/^[A-Za-z0-9]{8}$/', $project), 422, 'Invalid project id.');

        $versions = Http::timeout(10)->get(self::API . "/project/$project/version")->json() ?: [];

        return response()->json(['versions' => collect($versions)->map(fn ($v) => [
            'id' => $v['id'],
            'name' => $v['name'],
            'version_number' => $v['version_number'],
            'game_versions' => $v['game_versions'] ?? [],
            'loaders' => $v['loaders'] ?? [],
            'published_at' => $v['date_published'] ?? null,
        ])->take(50)->values()]);
    }

    public function installed(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ);

        return response()->json(['modpacks' => ModpackConfig::query()->where('server_id', $server->id)->get()
            ->map(fn (ModpackConfig $m) => ['id' => $m->id, 'name' => $m->modpack_name] + array_diff_key($m->config ?? [], ['files' => true]))]);
    }

    public function install(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_MOD_DOWNLOAD);
        $this->requirePermission($request, $server, Permission::ACTION_FILE_CREATE);
        $data = $request->validate([
            'project_id' => ['required', 'regex:/^[A-Za-z0-9]{8}$/'],
            'version_id' => ['required', 'regex:/^[A-Za-z0-9]{8}$/'],
        ]);

        $project = Http::timeout(10)->get(self::API . "/project/{$data['project_id']}")->json();
        $version = Http::timeout(10)->get(self::API . "/version/{$data['version_id']}")->json();
        if (!is_array($project) || !is_array($version) || ($version['project_id'] ?? null) !== $data['project_id']) {
            throw new HttpException(422, 'That modpack version was not found on Modrinth.');
        }

        $busy = ModpackConfig::query()->where('server_id', $server->id)->get()
            ->contains(fn (ModpackConfig $m) => in_array($m->config['status'] ?? null, ['queued', 'installing'], true));
        if ($busy) {
            throw new HttpException(409, 'A modpack is already being installed on this server.');
        }

        $row = ModpackConfig::query()->updateOrCreate(
            ['server_id' => $server->id, 'modpack_name' => (string) $project['title']],
            ['config' => [
                'project_id' => $data['project_id'],
                'version_id' => $data['version_id'],
                'version_name' => $version['version_number'] ?? $version['name'] ?? '',
                'icon_url' => $project['icon_url'] ?? null,
                'status' => 'queued',
                'progress' => 0,
                'total' => 0,
                'error' => null,
                'files' => [],
            ]],
        );

        InstallModpackJob::dispatch($row->id, $request->user()->id);
        Activity::event('server:modpack.install')->property('modpack', $project['title'])
            ->property('version', $row->config['version_name'])->log();

        return response()->json(['id' => $row->id], 202);
    }

    public function destroy(Request $request, Server $server, int $modpack): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_DELETE);
        $row = ModpackConfig::query()->where('server_id', $server->id)->findOrFail($modpack);

        $files = array_values(array_filter((array) ($row->config['files'] ?? []), fn ($f) => InstallModpackJob::safePath((string) $f)));
        if ($files !== []) {
            try {
                // One request per 100 files keeps the daemon payload small.
                foreach (array_chunk($files, 100) as $chunk) {
                    (Daemon::for($server))->delete('/', $chunk);
                }
            } catch (\Throwable $exception) {
                report($exception);
                throw new HttpException(502, 'Could not remove the modpack files from the server.');
            }
        }

        $row->delete();
        Activity::event('server:modpack.remove')->property('modpack', $row->modpack_name)->log();

        return response()->json([], 204);
    }

    private function requirePermission(Request $request, Server $server, string $permission): void
    {
        if (!$request->user()->can($permission, $server)) {
            throw new HttpException(403, 'You do not have permission to do that on this server.');
        }
    }
}
