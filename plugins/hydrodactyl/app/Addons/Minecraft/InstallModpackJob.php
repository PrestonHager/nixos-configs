<?php

namespace Pterodactyl\Addons\Minecraft;

use Pterodactyl\Jobs\Job;
use Pterodactyl\Models\Server;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Support\Facades\Http;
use Illuminate\Queue\SerializesModels;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Contracts\Queue\ShouldQueue;
use Pterodactyl\Addons\Minecraft\Models\ModpackConfig;

/**
 * Installs a Modrinth .mrpack onto a server:
 *  - files listed in modrinth.index.json are pulled by the daemon straight
 *    from their (allow-listed) download hosts;
 *  - overrides/ and server-overrides/ are written from the pack archive.
 * Every written path is recorded so ModpackController::destroy can undo it.
 */
class InstallModpackJob extends Job implements ShouldQueue
{
    use InteractsWithQueue;
    use Dispatchable;
    use SerializesModels;

    public int $timeout = 3600;

    public int $tries = 1;

    private const MAX_PACK_BYTES = 256 * 1024 * 1024;

    private const MAX_OVERRIDE_BYTES = 64 * 1024 * 1024;

    // Download hosts the .mrpack format allows (Modrinth spec).
    private const HOSTS = ['cdn.modrinth.com', 'github.com', 'raw.githubusercontent.com', 'gitlab.com'];

    public function __construct(public int $modpackId, public int $userId)
    {
        $this->onQueue('standard');
    }

    public function handle(): void
    {
        $row = ModpackConfig::query()->find($this->modpackId);
        if (!$row) {
            return;
        }

        $server = Server::query()->findOrFail($row->server_id);
        $daemon = Daemon::for($server);
        $config = $row->config;
        $files = [];
        $archive = null;

        try {
            $this->update($row, ['status' => 'installing', 'error' => null]);

            $version = Http::timeout(15)->get("https://api.modrinth.com/v2/version/{$config['version_id']}")->throw()->json();
            $pack = collect($version['files'] ?? [])->first(fn ($f) => ($f['primary'] ?? false) && str_ends_with($f['filename'] ?? '', '.mrpack'))
                ?? collect($version['files'] ?? [])->first(fn ($f) => str_ends_with($f['filename'] ?? '', '.mrpack'));
            if (!$pack || !$this->allowedUrl((string) $pack['url'])) {
                throw new \RuntimeException('This version has no installable .mrpack file.');
            }
            if (($pack['size'] ?? 0) > self::MAX_PACK_BYTES) {
                throw new \RuntimeException(sprintf('The modpack archive is %d MiB; the limit is %d MiB.', intdiv((int) $pack['size'], 1048576), intdiv(self::MAX_PACK_BYTES, 1048576)));
            }

            $archive = tempnam(sys_get_temp_dir(), 'mrpack');
            Http::timeout(600)->sink($archive)->get($pack['url'])->throw();
            if (!hash_equals((string) ($pack['hashes']['sha1'] ?? ''), (string) sha1_file($archive))) {
                throw new \RuntimeException('Downloaded modpack failed its checksum.');
            }

            $zip = new \ZipArchive();
            if ($zip->open($archive) !== true) {
                throw new \RuntimeException('The modpack archive could not be opened.');
            }

            $index = json_decode((string) $zip->getFromName('modrinth.index.json'), true);
            if (!is_array($index) || ($index['formatVersion'] ?? null) !== 1) {
                throw new \RuntimeException('Unsupported modpack format.');
            }

            $entries = array_values(array_filter($index['files'] ?? [], fn ($f) => ($f['env']['server'] ?? 'required') !== 'unsupported'));
            $overrides = [];
            for ($i = 0; $i < $zip->numFiles; $i++) {
                $name = (string) $zip->getNameIndex($i);
                if (preg_match('#^(server-overrides|overrides)/(.+[^/])$#', $name, $m) && self::safePath($m[2])) {
                    // server-overrides win over overrides for the same path.
                    if ($m[1] === 'server-overrides' || !isset($overrides[$m[2]])) {
                        $overrides[$m[2]] = $i;
                    }
                }
            }

            $this->update($row, ['total' => count($entries) + count($overrides), 'progress' => 0, 'dependencies' => $index['dependencies'] ?? []]);

            foreach ($entries as $n => $entry) {
                $path = (string) ($entry['path'] ?? '');
                $url = collect($entry['downloads'] ?? [])->first(fn ($u) => $this->allowedUrl((string) $u));
                if (!self::safePath($path) || !$url) {
                    throw new \RuntimeException("Refusing unsafe modpack entry \"$path\".");
                }

                $daemon->pull($url, dirname('/' . $path), basename($path));
                $files[] = $path;
                $this->update($row, ['progress' => $n + 1, 'files' => $files]);
            }

            $written = 0;
            foreach ($overrides as $path => $i) {
                $stat = $zip->statIndex($i);
                $written += (int) ($stat['size'] ?? 0);
                if ($written > self::MAX_OVERRIDE_BYTES) {
                    throw new \RuntimeException('Modpack overrides are larger than the 64 MiB limit.');
                }

                $daemon->write($path, (string) $zip->getFromIndex($i));
                $files[] = $path;
                $this->update($row, ['progress' => count($files), 'files' => $files]);
            }

            $zip->close();
            $this->update($row, ['status' => 'installed', 'progress' => count($files), 'files' => $files]);
        } catch (\Throwable $exception) {
            report($exception);
            $this->update($row, ['status' => 'failed', 'error' => $exception->getMessage(), 'files' => $files]);
        } finally {
            if ($archive && is_file($archive)) {
                @unlink($archive);
            }
        }
    }

    /**
     * Relative path inside the server root, no traversal.
     */
    public static function safePath(string $path): bool
    {
        return $path !== ''
            && !str_starts_with($path, '/')
            && !str_contains($path, '\\')
            && !in_array('..', explode('/', $path), true)
            && !preg_match('/[\x00-\x1f]/', $path);
    }

    private function allowedUrl(string $url): bool
    {
        $parts = parse_url($url);

        return ($parts['scheme'] ?? '') === 'https' && in_array(strtolower($parts['host'] ?? ''), self::HOSTS, true);
    }

    private function update(ModpackConfig $row, array $changes): void
    {
        $row->config = array_merge($row->config ?? [], $changes);
        $row->save();
    }
}
