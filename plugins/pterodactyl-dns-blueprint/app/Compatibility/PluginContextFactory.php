<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility;

class PluginContextFactory
{
    public function make(?object $plugin = null): PluginContext
    {
        return PluginContext::make();
    }
}
