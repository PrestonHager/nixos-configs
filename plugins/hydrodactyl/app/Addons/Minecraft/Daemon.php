<?php

namespace Pterodactyl\Addons\Minecraft;

use Pterodactyl\Models\Server;
use Pterodactyl\Repositories\Wings\DaemonFileRepository;
use Pterodactyl\Repositories\Wings\DaemonCommandRepository;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

/**
 * File and console access to a server through its node's daemon.
 *
 * Hydrodactyl keeps one repository namespace per daemon type (Wings, Elytra,
 * Calagopus) with the same method names; pick the matching one so this keeps
 * working if a node is ever switched away from Wings.
 */
class Daemon
{
    public function __construct(protected readonly Server $server)
    {
    }

    /**
     * Resolved through the container so tests can bind a recording fake.
     */
    public static function for(Server $server): static
    {
        return app(static::class, ['server' => $server]);
    }

    public function files(): DaemonFileRepository
    {
        return $this->repository('DaemonFileRepository', DaemonFileRepository::class);
    }

    /**
     * File contents, or null when the file does not exist. Wings 1.13 answers
     * a missing file with a 500 rather than a 404, so a failed read is
     * checked against the parent directory listing before it is rethrown.
     */
    public function read(string $path, int $limit = 2 * 1024 * 1024): ?string
    {
        try {
            return $this->files()->getContent($path, $limit);
        } catch (DaemonConnectionException $exception) {
            if ($this->isNotFound($exception) || !$this->exists($path)) {
                return null;
            }

            throw $exception;
        }
    }

    public function exists(string $path): bool
    {
        $name = basename($path);

        return collect($this->list(dirname('/' . ltrim($path, '/'))))->contains(fn ($f) => ($f['name'] ?? null) === $name);
    }

    public function write(string $path, string $content): void
    {
        $this->files()->putContent($path, $content);
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function list(string $directory): array
    {
        try {
            return $this->files()->getDirectory($directory);
        } catch (DaemonConnectionException $exception) {
            if ($this->isNotFound($exception)) {
                return [];
            }

            throw $exception;
        }
    }

    public function rename(string $root, string $from, string $to): void
    {
        $this->files()->renameFiles($root, [['from' => $from, 'to' => $to]]);
    }

    /**
     * @param string[] $files
     */
    public function delete(string $root, array $files): void
    {
        if ($files !== []) {
            $this->files()->deleteFiles($root, $files);
        }
    }

    public function pull(string $url, string $directory, string $filename): void
    {
        $this->files()->pull($url, $directory, ['filename' => $filename, 'foreground' => true]);
    }

    public function command(string $command): void
    {
        $this->repository('DaemonCommandRepository', DaemonCommandRepository::class)->send($command);
    }

    /**
     * @template T of object
     *
     * @param class-string<T> $fallback
     *
     * @return T
     */
    private function repository(string $name, string $fallback): object
    {
        $type = ucfirst(strtolower((string) ($this->server->node->daemonType ?? 'wings')));
        $class = "Pterodactyl\\Repositories\\{$type}\\{$name}";

        return app(class_exists($class) ? $class : $fallback)->setServer($this->server);
    }

    private function isNotFound(DaemonConnectionException $exception): bool
    {
        $previous = $exception->getPrevious();

        return is_object($previous)
            && method_exists($previous, 'getResponse')
            && $previous->getResponse()?->getStatusCode() === 404;
    }
}
