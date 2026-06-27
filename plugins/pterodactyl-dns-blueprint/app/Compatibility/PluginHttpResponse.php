<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility;

use Illuminate\Http\JsonResponse;

class PluginHttpResponse extends JsonResponse
{
    public static function json(array $data, int $status = 200): self
    {
        return new self($data, $status);
    }
}
