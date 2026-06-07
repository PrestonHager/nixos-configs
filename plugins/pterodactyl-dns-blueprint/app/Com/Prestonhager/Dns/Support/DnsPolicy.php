<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\Models\User;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class DnsPolicy
{
    public function ensureAdminDnsAccess(PluginHttpRequest $request): void
    {
        if (is_null($request->userId)) {
            throw new PluginException('Authentication is required.', 403);
        }

        $user = User::query()->find($request->userId);
        if (is_null($user) || !$user->root_admin) {
            throw new PluginException('Administrator access is required for DNS record management.', 403);
        }
    }

    public function isAdminUser(PluginHttpRequest $request): bool
    {
        if (is_null($request->userId)) {
            return false;
        }

        $user = User::query()->find($request->userId);

        return !is_null($user) && $user->root_admin;
    }

    public function isServerOwner(PluginHttpRequest $request, int $ownerId): bool
    {
        return !is_null($request->userId) && $request->userId === $ownerId;
    }

    public function canBypassSubdomainPolicy(PluginHttpRequest $request, int $ownerId): bool
    {
        return $this->isAdminUser($request) || $this->isServerOwner($request, $ownerId);
    }
}
