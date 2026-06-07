<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility;

use Exception;

class PluginException extends Exception
{
    public function __construct(string $message = '', int $code = 0, ?\Throwable $previous = null)
    {
        parent::__construct($message, $code, $previous);
    }
}
