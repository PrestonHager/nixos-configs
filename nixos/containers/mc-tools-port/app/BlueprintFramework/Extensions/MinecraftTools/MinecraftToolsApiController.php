<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools;

use Illuminate\Http\Request;
use Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models\ConfigBackup;
use Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models\IconHistory;
use Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models\ModpackConfig;
use Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models\PlayerNote;
use Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models\PluginConfig;
use Pterodactyl\Http\Controllers\Controller;

class MinecraftToolsApiController extends Controller
{
    public function __construct(
        private MinecraftToolsService $service,
    ) {
    }

    /* ------------------------------------------------------------------ */
    /* shared helpers                                                      */
    /* ------------------------------------------------------------------ */

    protected function serverId(Request $request): ?int
    {
        $user = $request->user();
        if (!$user) {
            return null;
        }

        $explicit = $request->query('server');
        if ($explicit !== null) {
            $server = $user->servers()->where('id', $explicit)->first();

            return $server?->id;
        }

        $server = $user->servers()->first();

        return $server?->id;
    }

    protected function ok(array $data = []): \Illuminate\Http\JsonResponse
    {
        return response()->json(array_merge(['status' => 'success'], $data));
    }

    protected function record(string $action, array $data = []): \Illuminate\Http\JsonResponse
    {
        return response()->json(array_merge([
            'status' => 'recorded',
            'wings' => false,
            'action' => $action,
            'message' => 'Recorded in the panel database; executing this action on the game server requires Wings integration which is not enabled on this deployment.',
        ], $data));
    }

    protected function notFound(string $message): \Illuminate\Http\JsonResponse
    {
        return response()->json(['status' => 'error', 'message' => $message], 404);
    }

    /* ------------------------------------------------------------------ */
    /* plugins                                                             */
    /* ------------------------------------------------------------------ */

    public function pluginsIndex(Request $request): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $rows = $serverId ? PluginConfig::where('server_id', $serverId)->get() : collect();

        $plugins = $rows->map(function (PluginConfig $row) {
            $config = $row->config ?? [];

            return [
                'name' => $row->plugin_name,
                'version' => $config['_version'] ?? null,
                'source' => $config['_source'] ?? 'local',
                'enabled' => $config['_enabled'] ?? true,
                'config' => array_diff_key($config, array_flip(['_version', '_source', '_enabled'])),
            ];
        });

        return $this->ok(['plugins' => $plugins, 'server' => $serverId]);
    }

    public function pluginStore(Request $request): \Illuminate\Http\JsonResponse
    {
        $validated = $request->validate([
            'name' => 'required|string',
            'version' => 'nullable|string',
            'source' => 'nullable|string',
            'source_id' => 'nullable|string',
        ]);

        $serverId = $this->serverId($request);
        if (!$serverId) {
            return $this->notFound('No accessible server to attach this plugin config to.');
        }

        $config = array_filter([
            '_version' => $validated['version'] ?? null,
            '_source' => $validated['source'] ?? ($validated['source_id'] ? 'remote' : 'local'),
            '_enabled' => true,
        ], fn ($v) => $v !== null);

        PluginConfig::updateOrCreate(
            ['server_id' => $serverId, 'plugin_name' => $validated['name']],
            ['config' => $config]
        );

        return $this->ok(['plugin' => ['name' => $validated['name']]]);
    }

    public function pluginShow(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? PluginConfig::where('server_id', $serverId)->where('plugin_name', $plugin)->first() : null;
        if (!$row) {
            return $this->notFound('Plugin not found on the selected server.');
        }

        return $this->ok(['plugin' => ['name' => $row->plugin_name, 'config' => $row->config]]);
    }

    public function pluginDestroy(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        if ($serverId) {
            PluginConfig::where('server_id', $serverId)->where('plugin_name', $plugin)->delete();
        }

        return $this->ok(['message' => 'Plugin config removed from the panel database.']);
    }

    public function pluginUpdate(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? PluginConfig::where('server_id', $serverId)->where('plugin_name', $plugin)->first() : null;
        if (!$row) {
            return $this->notFound('Plugin not found on the selected server.');
        }

        $config = $row->config ?? [];
        if ($request->boolean('enabled') !== null) {
            $config['_enabled'] = $request->boolean('enabled');
        }
        if ($request->has('config')) {
            $config = array_merge($config, $request->input('config'));
        }
        $row->update(['config' => $config]);

        return $this->ok(['plugin' => ['name' => $plugin]]);
    }

    public function pluginToggle(Request $request, string $plugin, string $state): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? PluginConfig::where('server_id', $serverId)->where('plugin_name', $plugin)->first() : null;
        if (!$row) {
            return $this->notFound('Plugin not found on the selected server.');
        }

        $config = $row->config ?? [];
        $config['_enabled'] = $state === 'enable';
        $row->update(['config' => $config]);

        return $this->ok(['message' => ucfirst($state) . 'd in the panel database; the game server must be restarted to apply real changes.']);
    }

    public function pluginGetConfig(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? PluginConfig::where('server_id', $serverId)->where('plugin_name', $plugin)->first() : null;

        return $this->ok(['config' => $row?->config ?? []]);
    }

    public function pluginUpdateConfig(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        $validated = $request->validate(['config' => 'required|array']);
        $serverId = $this->serverId($request);
        $row = $serverId ? PluginConfig::where('server_id', $serverId)->where('plugin_name', $plugin)->first() : null;
        if (!$row) {
            return $this->notFound('Plugin not found on the selected server.');
        }

        $merged = array_merge($row->config ?? [], $validated['config']);
        $row->update(['config' => $merged]);

        return $this->ok(['config' => $merged]);
    }

    public function pluginSearch(Request $request): \Illuminate\Http\JsonResponse
    {
        $query = (string) $request->input('query', '');
        $source = (string) $request->input('source', 'spigot');

        if ($query === '') {
            return $this->ok(['results' => [], 'source' => $source]);
        }

        $results = match ($source) {
            'modrinth' => $this->service->modrinthSearch($query)['hits'] ?? [],
            'curseforge' => [],
            default => $this->moderateSpigot($this->service->spigotSearch($query)),
        };

        return $this->ok(['results' => $results, 'source' => $source]);
    }

    public function pluginAvailable(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->pluginSearch($request);
    }

    public function pluginInstall(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        $this->pluginStore($request->merge(['name' => $plugin]));

        return $this->record('plugin.install', ['plugin' => $plugin]);
    }

    public function pluginUninstall(Request $request, string $plugin): \Illuminate\Http\JsonResponse
    {
        return $this->pluginDestroy($request, $plugin);
    }

    protected function moderateSpigot(array $items): array
    {
        return array_map(function ($item) {
            return [
                'id' => (string) ($item['id'] ?? ''),
                'name' => $item['name'] ?? 'Unknown',
                'tag' => $item['tag'] ?? '',
                'version' => $item['version'] ?? null,
            ];
        }, $items);
    }

    /* ------------------------------------------------------------------ */
    /* versions                                                            */
    /* ------------------------------------------------------------------ */

    public function versionsIndex(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok([
            'versions' => [],
            'current' => null,
            'message' => 'Installed server versions are managed through Wings; no version records exist yet.',
        ]);
    }

    public function versionsAvailable(Request $request): \Illuminate\Http\JsonResponse
    {
        $type = (string) $request->query('type', 'paper');

        $versions = match ($type) {
            'paper', 'spigot', 'purpur' => $this->service->paperVersions(),
            'fabric' => array_column($this->service->fabricVersions(), 'version'),
            default => [],
        };

        return $this->ok(['versions' => $versions, 'type' => $type]);
    }

    public function versionBuilds(Request $request, string $version): \Illuminate\Http\JsonResponse
    {
        $type = (string) $request->query('type', 'paper');
        $builds = match ($type) {
            'paper' => $this->service->paperBuilds($version),
            default => [],
        };

        return $this->ok(['builds' => $builds, 'version' => $version]);
    }

    public function versionInstall(Request $request): \Illuminate\Http\JsonResponse
    {
        $request->validate([
            'version' => 'required|string',
            'type' => 'required|string',
        ]);

        return $this->record('version.install', ['version' => $request->input('version'), 'type' => $request->input('type')]);
    }

    public function versionDestroy(Request $request, string $version): \Illuminate\Http\JsonResponse
    {
        return $this->record('version.remove', ['version' => $version]);
    }

    public function versionSwitch(Request $request): \Illuminate\Http\JsonResponse
    {
        $request->validate([
            'version' => 'required|string',
            'type' => 'required|string',
        ]);

        return $this->record('version.switch', ['version' => $request->input('version'), 'type' => $request->input('type')]);
    }

    public function versionCurrent(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['current' => null]);
    }

    /* ------------------------------------------------------------------ */
    /* players                                                             */
    /* ------------------------------------------------------------------ */

    public function playersIndex(Request $request): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $rows = $serverId ? PlayerNote::where('server_id', $serverId)->get() : collect();

        return $this->ok([
            'players' => $rows,
            'total' => $rows->count(),
            'message' => 'Live player lists require Wings integration; below are the recorded player notes for this server.',
        ]);
    }

    public function playerStore(Request $request): \Illuminate\Http\JsonResponse
    {
        $request->validate([
            'username' => 'required|string',
            'uuid' => 'nullable|string',
            'notes' => 'nullable|string',
            'display_name' => 'nullable|string',
        ]);

        $serverId = $this->serverId($request);
        if (!$serverId) {
            return $this->notFound('No accessible server to attach this player note to.');
        }

        PlayerNote::updateOrCreate(
            ['server_id' => $serverId, 'username' => $request->input('username')],
            [
                'uuid' => $request->input('uuid'),
                'notes' => $request->input('notes'),
                'display_name' => $request->input('display_name'),
            ]
        );

        return $this->ok(['player' => ['username' => $request->input('username')]]);
    }

    public function playerUpdate(Request $request, string $player): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? PlayerNote::where('server_id', $serverId)->where('username', $player)->first() : null;
        if (!$row) {
            return $this->notFound('Player not recorded on the selected server.');
        }

        $row->update(array_filter([
            'notes' => $request->input('notes'),
            'display_name' => $request->input('display_name'),
        ], fn ($v) => $v !== null));

        return $this->ok(['player' => ['username' => $player]]);
    }

    public function playerDestroy(Request $request, string $player): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        if ($serverId) {
            PlayerNote::where('server_id', $serverId)->where('username', $player)->delete();
        }

        return $this->ok(['message' => 'Player note removed.']);
    }

    public function playerAction(Request $request, string $player, string $action): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        if ($serverId) {
            PlayerNote::firstOrCreate(
                ['server_id' => $serverId, 'username' => $player],
                ['display_name' => $player]
            );
        }

        return $this->record('player.' . $action, ['player' => $player]);
    }

    public function playerLogs(Request $request, string $player): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['logs' => []]);
    }

    /* ------------------------------------------------------------------ */
    /* modpacks                                                            */
    /* ------------------------------------------------------------------ */

    public function modpacksIndex(Request $request): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $rows = $serverId ? ModpackConfig::where('server_id', $serverId)->get() : collect();

        $modpacks = $rows->map(function (ModpackConfig $row) {
            $config = $row->config ?? [];

            return [
                'name' => $row->modpack_name,
                'version' => $config['_version'] ?? null,
                'source' => $config['_source'] ?? 'local',
                'config' => array_diff_key($config, array_flip(['_version', '_source'])),
            ];
        });

        return $this->ok(['modpacks' => $modpacks, 'current' => null]);
    }

    public function modpackStore(Request $request): \Illuminate\Http\JsonResponse
    {
        $validated = $request->validate([
            'name' => 'required|string',
            'version' => 'nullable|string',
            'source' => 'nullable|string',
            'source_id' => 'nullable|string',
        ]);

        $serverId = $this->serverId($request);
        if (!$serverId) {
            return $this->notFound('No accessible server to attach this modpack config to.');
        }

        $config = array_filter([
            '_version' => $validated['version'] ?? null,
            '_source' => $validated['source'] ?? 'local',
        ], fn ($v) => $v !== null);

        ModpackConfig::updateOrCreate(
            ['server_id' => $serverId, 'modpack_name' => $validated['name']],
            ['config' => $config]
        );

        return $this->ok(['modpack' => ['name' => $validated['name']]]);
    }

    public function modpackShow(Request $request, string $modpack): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? ModpackConfig::where('server_id', $serverId)->where('modpack_name', $modpack)->first() : null;
        if (!$row) {
            return $this->notFound('Modpack not found on the selected server.');
        }

        return $this->ok(['modpack' => ['name' => $row->modpack_name, 'config' => $row->config]]);
    }

    public function modpackDestroy(Request $request, string $modpack): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        if ($serverId) {
            ModpackConfig::where('server_id', $serverId)->where('modpack_name', $modpack)->delete();
        }

        return $this->ok(['message' => 'Modpack config removed from the panel database.']);
    }

    public function modpackGetConfig(Request $request, string $modpack): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $row = $serverId ? ModpackConfig::where('server_id', $serverId)->where('modpack_name', $modpack)->first() : null;

        return $this->ok(['config' => $row?->config ?? []]);
    }

    public function modpackUpdateConfig(Request $request, string $modpack): \Illuminate\Http\JsonResponse
    {
        $validated = $request->validate(['config' => 'required|array']);
        $serverId = $this->serverId($request);
        $row = $serverId ? ModpackConfig::where('server_id', $serverId)->where('modpack_name', $modpack)->first() : null;
        if (!$row) {
            return $this->notFound('Modpack not found on the selected server.');
        }

        $merged = array_merge($row->config ?? [], $validated['config']);
        $row->update(['config' => $merged]);

        return $this->ok(['config' => $merged]);
    }

    public function modpackSearch(Request $request): \Illuminate\Http\JsonResponse
    {
        $query = (string) $request->input('query', '');
        $source = (string) $request->input('source', 'modrinth');

        if ($query === '') {
            return $this->ok(['results' => [], 'source' => $source]);
        }

        $results = [];
        if ($source === 'modrinth') {
            $results = array_map(function ($hit) {
                return [
                    'id' => $hit['project_id'] ?? '',
                    'name' => $hit['title'] ?? 'Unknown',
                    'description' => $hit['description'] ?? '',
                    'versions' => $hit['versions'] ?? [],
                ];
            }, $this->service->modrinthSearch($query)['hits'] ?? []);
        }

        return $this->ok(['results' => $results, 'source' => $source]);
    }

    public function modpackVersions(Request $request, string $modpack): \Illuminate\Http\JsonResponse
    {
        $source = (string) $request->query('source', 'modrinth');

        if ($source === 'modrinth') {
            return $this->ok(['versions' => $this->service->modrinthVersions($modpack)]);
        }

        return $this->ok(['versions' => []]);
    }

    public function modpackSwitchVersion(Request $request, string $modpack): \Illuminate\Http\JsonResponse
    {
        $request->validate(['version' => 'required|string']);

        return $this->record('modpack.switch', ['modpack' => $modpack, 'version' => $request->input('version')]);
    }

    public function modpackCategories(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['categories' => []]);
    }

    /* ------------------------------------------------------------------ */
    /* config editor                                                       */
    /* ------------------------------------------------------------------ */

    public function configIndex(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok([
            'configs' => [],
            'files' => $this->configFiles(),
            'message' => 'Server file reads/writes require Wings integration; config backups are stored in the panel database.',
        ]);
    }

    public function configListFiles(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['files' => $this->configFiles()]);
    }

    public function configShow(Request $request, string $file): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['config' => ['file' => $file], 'raw' => null]);
    }

    public function configGetRaw(Request $request, string $file): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['content' => null, 'message' => 'Reading this file requires Wings integration.']);
    }

    public function configUpdateRaw(Request $request, string $file): \Illuminate\Http\JsonResponse
    {
        $validated = $request->validate(['content' => 'required|string']);

        return $this->record('config.write', ['file' => $file, 'bytes' => strlen($validated['content'])]);
    }

    public function configBackup(Request $request, string $file): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        if (!$serverId) {
            return $this->notFound('No accessible server to store this backup for.');
        }

        $content = (string) $request->input('content', '');
        $backup = ConfigBackup::create([
            'server_id' => $serverId,
            'file' => $file,
            'content' => $content,
            'size' => strlen($content),
        ]);

        return $this->ok(['backup' => ['id' => (string) $backup->id, 'file' => $file]]);
    }

    public function configRestore(Request $request, string $file): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $id = (int) $request->input('backup_id', 0);
        $row = $serverId ? ConfigBackup::where('server_id', $serverId)->where('id', $id)->first() : null;
        if (!$row) {
            return $this->notFound('Backup not found.');
        }

        return $this->ok(['content' => $row->content]);
    }

    public function configTemplates(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['templates' => []]);
    }

    public function configValidate(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok(['valid' => true, 'errors' => []]);
    }

    protected function configFiles(): array
    {
        return [
            'server.properties',
            'spigot.yml',
            'bukkit.yml',
            'paper.yml',
            'pufferfish.yml',
            'purpur.yml',
            'fabric-server-launcher.properties',
            'forge-server.toml',
            'neoforge-server.toml',
        ];
    }

    /* ------------------------------------------------------------------ */
    /* icon                                                                */
    /* ------------------------------------------------------------------ */

    public function iconIndex(Request $request): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $latest = $serverId ? IconHistory::where('server_id', $serverId)->latest()->first() : null;

        return $this->ok(['icon' => $latest?->url]);
    }

    public function iconHistory(Request $request): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        $rows = $serverId ? IconHistory::where('server_id', $serverId)->latest()->limit(20)->get() : collect();

        return $this->ok(['history' => $rows]);
    }

    public function iconUpload(Request $request): \Illuminate\Http\JsonResponse
    {
        $request->validate(['image' => 'required|string']);

        $serverId = $this->serverId($request);
        if (!$serverId) {
            return $this->notFound('No accessible server to store this icon for.');
        }

        $url = IconHistory::create([
            'server_id' => $serverId,
            'url' => $request->input('image'),
            'size' => strlen($request->input('image')),
        ]);

        return $this->ok(['icon' => $url]);
    }

    public function iconGenerate(Request $request): \Illuminate\Http\JsonResponse
    {
        $text = (string) $request->input('text', 'MC');
        $background = (string) $request->input('background', '#2E86C1');
        $fontColor = (string) $request->input('font_color', '#FFFFFF');
        $fontSize = (int) $request->input('font_size', 24);

        $icon = $this->service->generateIcon($text, $background, $fontColor, $fontSize);
        if ($icon === null) {
            return $this->ok(['icon' => null, 'message' => 'GD image extension is not available in this panel container; server icon generation is disabled.']);
        }

        return $this->ok(['icon' => $icon]);
    }

    public function iconTemplates(Request $request): \Illuminate\Http\JsonResponse
    {
        return $this->ok([
            'templates' => [
                ['id' => 'default', 'name' => 'Default Minecraft'],
                ['id' => 'survival', 'name' => 'Survival'],
                ['id' => 'creative', 'name' => 'Creative'],
                ['id' => 'minigames', 'name' => 'Minigames'],
                ['id' => 'factions', 'name' => 'Factions'],
                ['id' => 'skyblock', 'name' => 'Skyblock'],
            ],
        ]);
    }

    public function iconDelete(Request $request): \Illuminate\Http\JsonResponse
    {
        $serverId = $this->serverId($request);
        if ($serverId) {
            IconHistory::where('server_id', $serverId)->delete();
        }

        return $this->ok(['message' => 'Icon history cleared from the panel database.']);
    }
}