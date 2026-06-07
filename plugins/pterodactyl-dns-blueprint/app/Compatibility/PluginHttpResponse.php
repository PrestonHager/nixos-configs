<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility;

use Illuminate\Http\JsonResponse;

class PluginHttpResponse
{
    public static function json(array $data, int $status = 200): JsonResponse
    {
        return response()->json($data, $status);
    }
}
