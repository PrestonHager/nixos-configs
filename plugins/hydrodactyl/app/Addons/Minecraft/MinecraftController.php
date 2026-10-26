<?php

namespace Pterodactyl\Addons\Minecraft;

use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Facades\Activity;
use Pterodactyl\Models\Permission;
use Pterodactyl\Models\ServerVariable;
use Illuminate\Support\Facades\Validator;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Servers\ReinstallServerService;
use Pterodactyl\Addons\Minecraft\Models\PlayerNote;
use Pterodactyl\Addons\Minecraft\Models\IconHistory;
use Pterodactyl\Addons\Minecraft\Models\ConfigBackup;
use Symfony\Component\HttpKernel\Exception\HttpException;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

/**
 * Minecraft tools for /api/client/servers/{server}/minecraft. Replaces the
 * Blueprint minecraft-tools port, which only recorded actions in the panel
 * database; everything here acts on the server through its daemon.
 *
 * Plugin/mod search and download is Hydrodactyl's native marketplace (the
 * "Installer" page); this adds what it lacks: enable/disable, versions,
 * players, server.properties, server icon and modpacks (ModpackController).
 */
class MinecraftController extends Controller
{
    private const PLAYER = '/^\.?[A-Za-z0-9_]{1,16}$/';

    public function __construct(
        private readonly VersionCatalog $catalog,
        private readonly ReinstallServerService $reinstall,
    ) {
    }

    public function overview(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ);
        $detected = $this->catalog->detect($server);

        return response()->json([
            'loader' => $detected['loader'],
            'addon_directory' => $this->addonDirectory($detected['loader']),
            'variables' => $detected['variables'],
        ]);
    }

    /* -------------------------------------------------------------- versions */

    public function versions(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_STARTUP_READ);
        $detected = $this->catalog->detect($server);

        return response()->json([
            'loader' => $detected['loader'],
            'variables' => $detected['variables'],
            'versions' => $detected['loader'] ? $this->catalog->versions($detected['loader']) : [],
        ]);
    }

    public function builds(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_STARTUP_READ);
        $version = (string) $request->query('version', '');
        $loader = $this->catalog->detect($server)['loader'];

        abort_unless($loader && preg_match('/^[0-9A-Za-z.\-+_]{1,40}$/', $version), 422, 'Invalid version.');

        return response()->json(['builds' => $this->catalog->builds($loader, $version)]);
    }

    /**
     * Set the egg's version variables, optionally reinstalling so the egg's
     * install script fetches the new jar. Same checks as the Startup page.
     */
    public function switchVersion(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_STARTUP_UPDATE);
        $data = $request->validate([
            'variables' => 'required|array|min:1',
            'variables.*' => 'nullable|string|max:191',
            'reinstall' => 'boolean',
        ]);

        $detected = $this->catalog->detect($server);
        $admin = (bool) $request->user()->root_admin;

        foreach ($data['variables'] as $env => $value) {
            $variable = $server->variables()->where('env_variable', $env)->first();
            if (!$variable || !array_key_exists($env, $detected['variables'])) {
                throw new HttpException(422, "$env is not a version variable of this egg.");
            }
            if (!$variable->user_editable && !$admin) {
                throw new HttpException(403, "$env is read-only for this server.");
            }

            // The egg's own rules first, then a strict version-string shape:
            // eggs often allow any short string here.
            Validator::make(['value' => $value], ['value' => $variable->rules])->validate();
            Validator::make(['value' => $value], ['value' => ['nullable', 'regex:/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,39}$/']])->validate();

            ServerVariable::query()->updateOrCreate(
                ['server_id' => $server->id, 'variable_id' => $variable->id],
                ['variable_value' => $value ?? ''],
            );

            Activity::event('server:startup.edit')->subject($variable)
                ->property(['variable' => $env, 'old' => $detected['variables'][$env]['value'], 'new' => $value])
                ->log();
        }

        if ($request->boolean('reinstall')) {
            $this->requirePermission($request, $server, Permission::ACTION_SETTINGS_REINSTALL);
            $this->reinstall->handle($server);
            Activity::event('server:reinstall')->log();
        }

        return $this->versions($request, $server->refresh());
    }

    /* ---------------------------------------------------------- plugins/mods */

    public function addons(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ);
        $directory = $this->addonDirectory($this->catalog->detect($server)['loader']);

        $files = collect($this->daemon($server, fn (Daemon $d) => $d->list($directory)))
            ->filter(fn ($f) => ($f['file'] ?? $f['is_file'] ?? true) && preg_match('/\.jar(\.disabled)?$/i', $f['name'] ?? ''))
            ->map(fn ($f) => [
                'file' => $f['name'],
                'name' => preg_replace('/\.jar(\.disabled)?$/i', '', $f['name']),
                'enabled' => !str_ends_with(strtolower($f['name']), '.disabled'),
                'size' => $f['size'] ?? 0,
                'modified_at' => $f['modified'] ?? $f['modified_at'] ?? null,
            ])
            ->sortBy('name', SORT_NATURAL | SORT_FLAG_CASE)
            ->values();

        return response()->json(['directory' => $directory, 'files' => $files]);
    }

    public function toggleAddon(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_UPDATE);
        $data = $request->validate(['file' => ['required', 'string', 'regex:/^[^\/\\\\]+\.jar(\.disabled)?$/i'], 'enabled' => 'required|boolean']);
        $directory = $this->addonDirectory($this->catalog->detect($server)['loader']);

        $base = preg_replace('/\.disabled$/i', '', $data['file']);
        $target = $data['enabled'] ? $base : $base . '.disabled';

        if ($target !== $data['file']) {
            $this->daemon($server, fn (Daemon $d) => $d->rename($directory, $data['file'], $target));
            Activity::event('server:file.rename')->property('directory', $directory)
                ->property('files', [['from' => $data['file'], 'to' => $target]])->log();
        }

        return response()->json(['file' => $target, 'enabled' => $data['enabled']]);
    }

    public function deleteAddon(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_DELETE);
        $data = $request->validate(['file' => ['required', 'string', 'regex:/^[^\/\\\\]+\.jar(\.disabled)?$/i']]);
        $directory = $this->addonDirectory($this->catalog->detect($server)['loader']);

        $this->daemon($server, fn (Daemon $d) => $d->delete($directory, [$data['file']]));
        Activity::event('server:file.delete')->property('directory', $directory)->property('files', [$data['file']])->log();

        return response()->json([], 204);
    }

    /* --------------------------------------------------------------- players */

    public function players(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ_CONTENT);

        $read = fn (string $file) => (array) (json_decode((string) $this->daemon($server, fn (Daemon $d) => $d->read($file)), true) ?: []);
        [$whitelist, $ops, $banned, $cache] = [$read('whitelist.json'), $read('ops.json'), $read('banned-players.json'), $read('usercache.json')];

        $players = [];
        $touch = function (array $entry) use (&$players) {
            $name = (string) ($entry['name'] ?? '');
            if ($name !== '') {
                $players[strtolower($name)] ??= ['name' => $name, 'uuid' => $entry['uuid'] ?? null, 'whitelisted' => false, 'op' => false, 'op_level' => null, 'banned' => false, 'ban_reason' => null, 'notes' => null];
            }

            return strtolower($name);
        };

        foreach ($cache as $e) { $touch($e); }
        foreach ($whitelist as $e) { $players[$touch($e)]['whitelisted'] = true; }
        foreach ($ops as $e) { $k = $touch($e); $players[$k]['op'] = true; $players[$k]['op_level'] = $e['level'] ?? null; }
        foreach ($banned as $e) { $k = $touch($e); $players[$k]['banned'] = true; $players[$k]['ban_reason'] = $e['reason'] ?? null; }

        foreach (PlayerNote::query()->where('server_id', $server->id)->get() as $note) {
            $k = $touch(['name' => $note->username, 'uuid' => $note->uuid]);
            $players[$k]['notes'] = $note->notes;
        }
        unset($players['']);

        return response()->json(['players' => array_values(collect($players)->sortBy('name', SORT_NATURAL | SORT_FLAG_CASE)->all())]);
    }

    public function playerAction(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_CONTROL_CONSOLE);
        $data = $request->validate([
            'player' => ['required', 'string', 'regex:' . self::PLAYER],
            'action' => 'required|in:whitelist,unwhitelist,op,deop,ban,unban,kick',
            'reason' => 'nullable|string|max:200',
        ]);

        $reason = trim(preg_replace('/[\r\n]+/', ' ', (string) ($data['reason'] ?? '')));
        $command = match ($data['action']) {
            'whitelist' => "whitelist add {$data['player']}",
            'unwhitelist' => "whitelist remove {$data['player']}",
            'op' => "op {$data['player']}",
            'deop' => "deop {$data['player']}",
            'ban' => trim("ban {$data['player']} $reason"),
            'unban' => "pardon {$data['player']}",
            'kick' => trim("kick {$data['player']} $reason"),
        };

        $this->daemon($server, fn (Daemon $d) => $d->command($command), offlineMessage: 'Start the server first: player actions run as console commands.');
        Activity::event('server:console.command')->property('command', $command)->log();

        return response()->json(['command' => $command]);
    }

    public function playerNotes(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_UPDATE);
        $data = $request->validate([
            'player' => ['required', 'string', 'regex:' . self::PLAYER],
            'uuid' => 'nullable|uuid',
            'notes' => 'nullable|string|max:5000',
        ]);

        PlayerNote::query()->updateOrCreate(
            ['server_id' => $server->id, 'username' => $data['player']],
            ['uuid' => $data['uuid'] ?? null, 'notes' => $data['notes'] ?? null, 'display_name' => $data['player']],
        );

        return response()->json([], 204);
    }

    /* ------------------------------------------------------------ properties */

    public function properties(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ_CONTENT);
        $content = $this->daemon($server, fn (Daemon $d) => $d->read('server.properties'));

        return response()->json([
            'exists' => $content !== null,
            'values' => ServerProperties::parse((string) $content),
            'fields' => collect(ServerProperties::FIELDS)->map(fn ($f) => ['type' => $f[0], 'options' => $f[1]]),
            'locked' => ServerProperties::LOCKED,
        ]);
    }

    public function updateProperties(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_UPDATE);
        $data = $request->validate(['values' => 'required|array']);

        $current = (string) $this->daemon($server, fn (Daemon $d) => $d->read('server.properties'));
        $updated = ServerProperties::apply($current, $data['values']);

        if ($updated !== $current) {
            $this->backup($server, 'server.properties', $current);
            $this->daemon($server, fn (Daemon $d) => $d->write('server.properties', $updated));
            Activity::event('server:file.write')->property('file', '/server.properties')->log();
        }

        return $this->properties($request, $server);
    }

    public function propertyBackups(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ_CONTENT);

        return response()->json(['backups' => ConfigBackup::query()
            ->where('server_id', $server->id)->where('file', 'server.properties')
            ->orderByDesc('id')->limit(20)->get(['id', 'size', 'created_at'])]);
    }

    public function restorePropertyBackup(Request $request, Server $server, int $backup): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_UPDATE);
        $row = ConfigBackup::query()->where('server_id', $server->id)->findOrFail($backup);

        $current = (string) $this->daemon($server, fn (Daemon $d) => $d->read($row->file));
        $this->backup($server, $row->file, $current);
        $this->daemon($server, fn (Daemon $d) => $d->write($row->file, $row->content));
        Activity::event('server:file.write')->property('file', '/' . $row->file)->log();

        return $this->properties($request, $server);
    }

    /* ------------------------------------------------------------------ icon */

    public function icon(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ_CONTENT);
        $png = $this->daemon($server, fn (Daemon $d) => $d->read('server-icon.png', 512 * 1024));

        return response()->json([
            'icon' => $png ? 'data:image/png;base64,' . base64_encode($png) : null,
            'history' => IconHistory::query()->where('server_id', $server->id)->orderByDesc('id')->limit(12)
                ->get(['id', 'image', 'created_at']),
        ]);
    }

    public function uploadIcon(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_UPDATE);
        $data = $request->validate(['image' => 'required|string|max:4000000']);

        $this->saveIcon($server, IconImage::fromDataUri($data['image']));

        return $this->icon($request, $server);
    }

    public function generateIcon(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_READ);
        $data = $request->validate([
            'text' => 'required|string|max:4',
            'background' => ['required', 'regex:/^#[0-9a-f]{6}$/i'],
            'color' => ['required', 'regex:/^#[0-9a-f]{6}$/i'],
        ]);

        return response()->json(['image' => 'data:image/png;base64,' . base64_encode(
            IconImage::generate($data['text'], $data['background'], $data['color'])
        )]);
    }

    public function restoreIcon(Request $request, Server $server, int $history): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_UPDATE);
        $row = IconHistory::query()->where('server_id', $server->id)->findOrFail($history);
        abort_unless($row->image, 404, 'This history entry has no stored image.');

        $this->saveIcon($server, IconImage::fromDataUri($row->image));

        return $this->icon($request, $server);
    }

    public function deleteIcon(Request $request, Server $server): JsonResponse
    {
        $this->requirePermission($request, $server, Permission::ACTION_FILE_DELETE);
        $this->daemon($server, fn (Daemon $d) => $d->delete('/', ['server-icon.png']));
        Activity::event('server:file.delete')->property('directory', '/')->property('files', ['server-icon.png'])->log();

        return $this->icon($request, $server);
    }

    /* --------------------------------------------------------------- helpers */

    private function saveIcon(Server $server, string $png): void
    {
        $this->daemon($server, fn (Daemon $d) => $d->write('server-icon.png', $png));
        IconHistory::query()->create([
            'server_id' => $server->id,
            'url' => 'server-icon.png',
            'image' => 'data:image/png;base64,' . base64_encode($png),
            'size' => strlen($png),
        ]);
        Activity::event('server:file.write')->property('file', '/server-icon.png')->log();
    }

    private function backup(Server $server, string $file, string $content): void
    {
        if ($content === '') {
            return;
        }

        ConfigBackup::query()->create(['server_id' => $server->id, 'file' => $file, 'content' => $content, 'size' => strlen($content)]);

        // Keep the newest 20 per file.
        $keep = ConfigBackup::query()->where('server_id', $server->id)->where('file', $file)
            ->orderByDesc('id')->limit(20)->pluck('id');
        ConfigBackup::query()->where('server_id', $server->id)->where('file', $file)->whereNotIn('id', $keep)->delete();
    }

    public static function addonDirectory(?string $loader): string
    {
        return in_array($loader, ['paper', 'purpur'], true) ? 'plugins' : 'mods';
    }

    private function requirePermission(Request $request, Server $server, string $permission): void
    {
        if (!$request->user()->can($permission, $server)) {
            throw new HttpException(403, 'You do not have permission to do that on this server.');
        }
    }

    /**
     * @template T
     *
     * @param callable(Daemon): T $callback
     *
     * @return T
     */
    private function daemon(Server $server, callable $callback, string $offlineMessage = 'The server\'s node could not be reached.'): mixed
    {
        try {
            return $callback(Daemon::for($server));
        } catch (DaemonConnectionException $exception) {
            throw new HttpException(502, $offlineMessage, $exception);
        }
    }
}
