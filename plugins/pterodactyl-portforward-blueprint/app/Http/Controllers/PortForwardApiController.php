<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Services;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;
use Pterodactyl\Http\Controllers\Controller;

class PortForwardApiController extends Controller
{
    public function mappingsIndex(int $server): JsonResponse
    {
        $context = PluginContext::make();
        $overview = Services::overview($context)->build($server);

        return response()->json($overview);
    }

    public function mappingsStore(Request $request, int $server): JsonResponse
    {
        $validated = $request->validate([
            'protocol' => 'required|in:tcp,udp',
            'external_port' => 'required|integer|min:1|max:65535',
            'internal_port' => 'nullable|integer|min:1|max:65535',
        ]);

        try {
            $mapping = Services::routerNat(PluginContext::make())->createMapping(
                $server,
                $validated['protocol'],
                (int) $validated['external_port'],
                isset($validated['internal_port']) ? (int) $validated['internal_port'] : null,
            );

            return response()->json(['mapping' => $mapping], 201);
        } catch (PluginException $e) {
            return response()->json(['error' => $e->getMessage()], 422);
        }
    }

    public function mappingsDestroy(int $server, string $mappingId): JsonResponse
    {
        try {
            Services::routerNat(PluginContext::make())->removeMapping($server, $mappingId);

            return response()->json(['success' => true]);
        } catch (PluginException $e) {
            return response()->json(['error' => $e->getMessage()], 422);
        }
    }

    public function forwardPrimary(int $server): JsonResponse
    {
        try {
            $mapping = Services::routerNat(PluginContext::make())->forwardPrimaryAllocation($server);
            if (is_null($mapping)) {
                return response()->json(['error' => 'No primary allocation found.'], 422);
            }

            return response()->json(['mapping' => $mapping], 201);
        } catch (PluginException $e) {
            return response()->json(['error' => $e->getMessage()], 422);
        }
    }

    public function forwardAllocation(int $server, int $allocationId): JsonResponse
    {
        try {
            $mapping = Services::routerNat(PluginContext::make())->forwardAllocation($server, $allocationId);

            return response()->json(['mapping' => $mapping], 201);
        } catch (PluginException $e) {
            return response()->json(['error' => $e->getMessage()], 422);
        }
    }

    public function auditIndex(Request $request): JsonResponse
    {
        $serverId = $request->query('server_id');
        $context = PluginContext::make();

        return response()->json([
            'entries' => Services::audit($context)->recent(50, is_numeric($serverId) ? (int) $serverId : null),
        ]);
    }

    public function testConnection(): JsonResponse
    {
        try {
            return response()->json(Services::routerNat(PluginContext::make())->testConnection());
        } catch (PluginException $e) {
            return response()->json(['success' => false, 'error' => $e->getMessage()], 422);
        }
    }
}
