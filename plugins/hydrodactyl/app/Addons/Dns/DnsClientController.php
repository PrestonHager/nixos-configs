<?php

namespace Pterodactyl\Addons\Dns;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\Permission;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\SubdomainController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\SrvProfilesController;

/**
 * Client-facing DNS endpoints (/api/client/servers/{server}/dns/...).
 *
 * The Blueprint extension sent client calls through the admin adapter
 * (isAdmin: true, no ownership check). Here the route sits behind
 * AuthenticateServerAccess and the request carries the caller's real admin
 * flag, so client_subdomain_policy and the change limits apply.
 */
class DnsClientController extends Controller
{
    public function __construct(
        private readonly SubdomainController $subdomain,
        private readonly SrvProfilesController $srvProfiles,
    ) {
    }

    public function subdomainShow(Request $request, Server $server): JsonResponse
    {
        return $this->invoke($this->subdomain, 'show', $request, $server, Permission::ACTION_ALLOCATION_READ);
    }

    public function subdomainUpdate(Request $request, Server $server): JsonResponse
    {
        return $this->invoke($this->subdomain, 'update', $request, $server, Permission::ACTION_ALLOCATION_UPDATE);
    }

    public function subdomainCheck(Request $request, Server $server): JsonResponse
    {
        return $this->invoke($this->subdomain, 'check', $request, $server, Permission::ACTION_ALLOCATION_READ);
    }

    public function srvProfilesIndex(Request $request, Server $server): JsonResponse
    {
        return $this->invoke($this->srvProfiles, 'index', $request, $server, Permission::ACTION_ALLOCATION_READ);
    }

    public function srvProfilesUpdate(Request $request, Server $server): JsonResponse
    {
        return $this->invoke($this->srvProfiles, 'update', $request, $server, Permission::ACTION_ALLOCATION_UPDATE);
    }

    public function srvProfilesSync(Request $request, Server $server): JsonResponse
    {
        return $this->invoke($this->srvProfiles, 'sync', $request, $server, Permission::ACTION_ALLOCATION_UPDATE);
    }

    private function invoke(object $controller, string $method, Request $request, Server $server, string $permission): JsonResponse
    {
        if (!$request->user()->can($permission, $server)) {
            return $this->error(403, 'You do not have permission to manage DNS for this server.');
        }

        try {
            return $controller->{$method}(PluginContext::make(), PluginHttpRequest::fromClientRequest($request, $server));
        } catch (PluginException $exception) {
            return $this->error($exception->getCode() >= 400 ? $exception->getCode() : 422, $exception->getMessage());
        } catch (\Throwable $exception) {
            report($exception);

            return $this->error(500, 'DNS request failed.');
        }
    }

    private function error(int $status, string $detail): JsonResponse
    {
        return response()->json(['errors' => [['code' => 'DnsError', 'status' => (string) $status, 'detail' => $detail]]], $status);
    }
}
