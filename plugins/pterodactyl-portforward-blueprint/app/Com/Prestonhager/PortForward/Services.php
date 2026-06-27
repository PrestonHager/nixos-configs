<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Ssh\SshClient;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\AuditLog;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\MappingState;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\NodeIpResolver;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\PortValidator;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\ServerForwardOverview;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;

final class Services
{
    public static function config(PluginContext $context): Config
    {
        return new Config($context);
    }

    public static function state(PluginContext $context): MappingState
    {
        return new MappingState($context);
    }

    public static function audit(PluginContext $context): AuditLog
    {
        return new AuditLog();
    }

    public static function ssh(PluginContext $context): SshClient
    {
        return new SshClient(self::config($context));
    }

    public static function routerNat(PluginContext $context): RouterNatService
    {
        $config = self::config($context);

        return new RouterNatService(
            $context,
            $config,
            new PortValidator($config),
            new NodeIpResolver($context, $config),
            self::state($context),
            self::ssh($context),
            self::audit($context),
        );
    }

    public static function overview(PluginContext $context): ServerForwardOverview
    {
        $config = self::config($context);

        return new ServerForwardOverview(
            $context,
            $config,
            self::state($context),
            new NodeIpResolver($context, $config),
        );
    }
}
