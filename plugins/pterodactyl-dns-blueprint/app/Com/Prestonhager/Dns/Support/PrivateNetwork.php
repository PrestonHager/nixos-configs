<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

final class PrivateNetwork
{
    public static function isPrivateLan(string $value): bool
    {
        $value = trim($value);
        if ($value === '' || !filter_var($value, FILTER_VALIDATE_IP)) {
            return false;
        }

        return filter_var(
            $value,
            FILTER_VALIDATE_IP,
            FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE
        ) === false;
    }
}
