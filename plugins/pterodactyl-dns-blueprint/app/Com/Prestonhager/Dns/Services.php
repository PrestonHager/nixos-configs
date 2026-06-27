<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\Client;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\DnsService;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\SrvProvisioner;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare\SrvRecordMatcher;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers\CloudflareProvider;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers\ProviderManager;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Providers\TechnitiumProvider;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\AuditLog;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Technitium\Client as TechnitiumClient;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\DnsLookupService;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\DnsPolicy;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\HostnameManager;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\HostnameRegistry;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ServerDnsState;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\SubdomainValidator;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ZoneResolver;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

final class Services
{
    public static function config(PluginContext $context): Config
    {
        return new Config($context);
    }

    public static function state(PluginContext $context): ServerDnsState
    {
        return new ServerDnsState($context);
    }

    public static function dnsPolicy(PluginContext $context): DnsPolicy
    {
        return new DnsPolicy();
    }

    public static function client(PluginContext $context): Client
    {
        return new Client($context, self::config($context));
    }

    public static function zoneResolver(PluginContext $context): ZoneResolver
    {
        return new ZoneResolver(self::client($context), self::config($context));
    }

    public static function srvMatcher(PluginContext $context): SrvRecordMatcher
    {
        return new SrvRecordMatcher(self::client($context));
    }

    public static function hostnameRegistry(PluginContext $context): HostnameRegistry
    {
        return new HostnameRegistry($context, self::config($context), self::client($context));
    }

    public static function subdomainValidator(PluginContext $context): SubdomainValidator
    {
        return new SubdomainValidator(
            self::config($context),
            self::dnsPolicy($context),
            self::hostnameRegistry($context),
            self::state($context),
        );
    }

    public static function hostnameManager(PluginContext $context): HostnameManager
    {
        return new HostnameManager(
            $context,
            self::config($context),
            self::client($context),
            self::state($context),
            self::srvProvisioner($context),
            self::hostnameRegistry($context),
        );
    }

    public static function dnsLookup(PluginContext $context): DnsLookupService
    {
        return new DnsLookupService();
    }

    public static function dns(PluginContext $context): DnsService
    {
        $config = self::config($context);

        return new DnsService(
            $context,
            $config,
            self::client($context),
            self::state($context),
            self::zoneResolver($context),
        );
    }

    public static function auditLog(PluginContext $context): AuditLog
    {
        return new AuditLog();
    }

    public static function technitiumClient(PluginContext $context): TechnitiumClient
    {
        return new TechnitiumClient($context, self::config($context));
    }

    public static function cloudflareProvider(PluginContext $context): CloudflareProvider
    {
        return new CloudflareProvider(self::client($context));
    }

    public static function technitiumProvider(PluginContext $context): TechnitiumProvider
    {
        return new TechnitiumProvider(self::technitiumClient($context), self::config($context));
    }

    public static function providerManager(PluginContext $context): ProviderManager
    {
        $config = self::config($context);

        return new ProviderManager(
            $context,
            $config,
            self::cloudflareProvider($context),
            self::technitiumProvider($context),
            self::auditLog($context),
        );
    }

    public static function srvProvisioner(PluginContext $context): SrvProvisioner
    {
        $config = self::config($context);

        return new SrvProvisioner(
            $context,
            $config,
            self::client($context),
            self::state($context),
            self::srvMatcher($context),
            self::providerManager($context),
        );
    }
}
