<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility;

use Illuminate\Http\Request;
use Pterodactyl\Models\Server;

class PluginHttpRequest
{
    public function __construct(
        public readonly Request $request,
        public readonly ?int $userId = null,
        public readonly ?int $serverId = null,
        public readonly array $body = [],
        public readonly array $query = [],
        public readonly array $route = [],
        public readonly bool $isAdmin = false,
    ) {
    }

    public function route(string $key, mixed $default = null): mixed
    {
        return $this->route[$key] ?? $default;
    }

    public static function fromApplicationRequest(Request $request): self
    {
        $server = self::resolveServer($request);

        return new self(
            request: $request,
            userId: optional($request->user())->id,
            serverId: $server?->id,
            body: $request->all(),
            query: $request->query(),
            route: $request->route()?->parameters() ?? [],
            isAdmin: true,
        );
    }

    public static function fromClientRequest(Request $request, Server $server): self
    {
        return new self(
            request: $request,
            userId: optional($request->user())->id,
            serverId: $server->id,
            body: $request->all(),
            query: $request->query(),
            route: array_merge($request->route()?->parameters() ?? [], ['server' => $server->uuid]),
            isAdmin: optional($request->user())->root_admin ?? false,
        );
    }

    private static function resolveServer(Request $request): ?Server
    {
        $serverParam = $request->route('server');

        if ($serverParam instanceof Server) {
            return $serverParam;
        }

        if (is_numeric($serverParam)) {
            return Server::query()->find((int) $serverParam);
        }

        if (is_string($serverParam) && $serverParam !== '') {
            return Server::query()->where('uuid', $serverParam)->orWhere('uuidShort', $serverParam)->first();
        }

        return null;
    }
}
