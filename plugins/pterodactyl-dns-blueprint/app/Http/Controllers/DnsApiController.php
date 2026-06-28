<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\RecordsController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\SrvProfilesController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http\SubdomainController;

class DnsApiController
{
    public function __construct(
        private readonly RecordsController $records,
        private readonly SrvProfilesController $srvProfiles,
        private readonly SubdomainController $subdomain,
    ) {
    }

    public function recordsIndex(Request $request): JsonResponse
    {
        return $this->invoke($this->records, 'index', $request);
    }

    public function recordsStore(Request $request): JsonResponse
    {
        return $this->invoke($this->records, 'store', $request);
    }

    public function recordsUpdate(Request $request, string $recordId): JsonResponse
    {
        $request->route()->setParameter('recordId', $recordId);

        return $this->invoke($this->records, 'update', $request);
    }

    public function recordsDestroy(Request $request, string $recordId): JsonResponse
    {
        $request->route()->setParameter('recordId', $recordId);

        return $this->invoke($this->records, 'destroy', $request);
    }

    public function recordsDestroyByBody(Request $request): JsonResponse
    {
        return $this->invoke($this->records, 'destroy', $request);
    }

    public function srvProfilesIndex(Request $request): JsonResponse
    {
        return $this->invoke($this->srvProfiles, 'index', $request);
    }

    public function srvProfilesUpdate(Request $request): JsonResponse
    {
        return $this->invoke($this->srvProfiles, 'update', $request);
    }

    public function srvProfilesSync(Request $request): JsonResponse
    {
        return $this->invoke($this->srvProfiles, 'sync', $request);
    }

    public function subdomainShow(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'show', $request);
    }

    public function subdomainUpdate(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'update', $request);
    }

    public function subdomainCheck(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'check', $request);
    }

    public function subdomainRegenerate(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'regenerate', $request);
    }

    public function customDomainShow(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'showCustomDomain', $request);
    }

    public function customDomainUpdate(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'updateCustomDomain', $request);
    }

    public function customDomainVerify(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'verifyCustomDomain', $request);
    }

    public function nameserverShow(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'showNameserver', $request);
    }

    public function nameserverUpdate(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'updateNameserver', $request);
    }

    public function nameserverVerify(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'verifyNameserver', $request);
    }

    public function pendingNameserverDelegations(Request $request): JsonResponse
    {
        return $this->invoke($this->subdomain, 'pendingNameserverDelegations', $request);
    }

    public function approveNameserverDelegation(Request $request, int $server): JsonResponse
    {
        $request->route()->setParameter('server', $server);

        return $this->invoke($this->subdomain, 'approveNameserverDelegation', $request);
    }

    private function invoke(object $controller, string $method, Request $request): JsonResponse
    {
        try {
            $context = PluginContext::make();
            $pluginRequest = PluginHttpRequest::fromApplicationRequest($request);
            $response = $controller->{$method}($context, $pluginRequest);

            return $response;
        } catch (PluginException $exception) {
            $status = $exception->getCode() >= 400 ? $exception->getCode() : 422;

            return response()->json([
                'errors' => [[
                    'code' => 'PluginException',
                    'status' => (string) $status,
                    'detail' => $exception->getMessage(),
                ]],
            ], $status);
        } catch (\Throwable $exception) {
            report($exception);

            return response()->json([
                'errors' => [[
                    'code' => class_basename($exception),
                    'status' => '500',
                    'detail' => $exception->getMessage(),
                ]],
            ], 500);
        }
    }
}
