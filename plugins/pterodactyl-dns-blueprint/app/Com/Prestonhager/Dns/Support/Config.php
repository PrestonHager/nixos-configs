<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class Config
{
    public function __construct(
        private readonly PluginContext $context,
    ) {
    }

    public function dnsProviderMode(): string
    {
        $value = (string) $this->context->config()->get('dns_provider_mode', 'cloudflare');
        $allowed = ['cloudflare', 'technitium', 'both'];

        return in_array($value, $allowed, true) ? $value : 'cloudflare';
    }

    public function technitiumApiUrl(): string
    {
        $value = $this->context->config()->get('technitium_api_url', 'http://host.containers.internal:5380');

        return is_string($value) && trim($value) !== ''
            ? rtrim(trim($value), '/')
            : 'http://host.containers.internal:5380';
    }

    public function technitiumApiToken(): string
    {
        $file = getenv('TECHNITIUM_API_TOKEN_FILE') ?: '';
        if ($file !== '' && is_readable($file)) {
            $contents = trim((string) file_get_contents($file));
            if ($contents !== '') {
                return $contents;
            }
        }

        $env = getenv('TECHNITIUM_API_TOKEN') ?: '';
        if ($env !== '') {
            return $env;
        }

        return $this->optionalString('technitium_api_token');
    }

    public function technitiumDefaultZone(): string
    {
        $value = $this->context->config()->get('technitium_default_zone', 'prestonhager.com');

        return is_string($value) && trim($value) !== '' ? trim($value) : 'prestonhager.com';
    }

    public function dryRunEnabled(): bool
    {
        $value = $this->context->config()->get('dry_run', false);

        return filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) ?? (bool) $value;
    }

    public function updateOnAllocationChange(): bool
    {
        $value = $this->context->config()->get('update_on_allocation_change', true);

        return filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) ?? (bool) $value;
    }

    /**
     * @return array<string, string>
     */
    public function nodeFqdnMap(): array
    {
        $raw = $this->context->config()->get('node_fqdn_map', []);
        if (!is_array($raw)) {
            return $this->defaultNodeFqdnMap();
        }

        $map = [];
        foreach ($raw as $key => $value) {
            if (!is_string($key) || !is_string($value)) {
                continue;
            }

            $fqdn = strtolower(rtrim(trim($value), '.'));
            if ($fqdn !== '') {
                $map[(string) $key] = $fqdn;
            }
        }

        return $map !== [] ? $map : $this->defaultNodeFqdnMap();
    }

    /**
     * @return array<string, string>
     */
    private function defaultNodeFqdnMap(): array
    {
        return [
            '1' => 'crux.lc1.nm.us.prestonhager.com',
            '2' => 'nova.lc1.nm.us.prestonhager.com',
            'default_crux' => 'crux.lc1.nm.us.prestonhager.com',
            'default_nova' => 'nova.lc1.nm.us.prestonhager.com',
        ];
    }

    public function hasCloudflare(): bool
    {
        try {
            return $this->cloudflareApiToken() !== '' && $this->zoneId() !== '';
        } catch (PluginException) {
            return false;
        }
    }

    public function hasTechnitium(): bool
    {
        return $this->technitiumApiToken() !== '';
    }

    /**
     * @return string[]
     */
    public function infraReservedLabels(): array
    {
        return [
            'ace', 'crux', 'nova', 'panel', 'dns', 'grafana', 'cloud', 'game', 'mc',
            'factorio', 'jellyfin', 'vault', 'zitadel', 'git', 'matrix', 'vpn', 'wg',
        ];
    }

    public function cloudflareApiToken(): string
    {
        $file = getenv('CLOUDFLARE_API_TOKEN_FILE') ?: '';
        if ($file !== '' && is_readable($file)) {
            $contents = trim((string) file_get_contents($file));
            if ($contents !== '') {
                return $contents;
            }
        }

        $env = getenv('CLOUDFLARE_API_TOKEN') ?: '';
        if ($env !== '') {
            return $env;
        }

        return $this->optionalString('cloudflare_api_token');
    }

    public function zoneId(): string
    {
        return $this->optionalString('zone_id');
    }

    public function baseDomain(): string
    {
        $value = $this->optionalString('base_domain');

        return $value !== '' ? rtrim($value, '.') : 'prestonhager.com';
    }

    public function defaultTtl(): int
    {
        $ttl = $this->context->config()->get('default_ttl', 1);

        return is_numeric($ttl) ? (int) $ttl : 1;
    }

    public function autoProvisionEnabled(): bool
    {
        $value = $this->context->config()->get('auto_provision_enabled', true);

        return filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) ?? (bool) $value;
    }

    public function subdomainGeneration(): string
    {
        $value = (string) $this->context->config()->get('subdomain_generation', 'server_slug');
        $allowed = ['server_slug', 'random_words', 'random_hex', 'uuid_only'];

        return in_array($value, $allowed, true) ? $value : 'server_slug';
    }

    public function clientSubdomainPolicy(): string
    {
        $value = (string) $this->context->config()->get('client_subdomain_policy', 'never');
        $allowed = ['never', 'once_on_create', 'limited', 'always'];

        return in_array($value, $allowed, true) ? $value : 'never';
    }

    public function clientChangeLimit(): int
    {
        return max(0, (int) $this->context->config()->get('client_change_limit', 1));
    }

    public function clientChangePeriodHours(): int
    {
        return max(1, (int) $this->context->config()->get('client_change_period_hours', 168));
    }

    public function minLabelLength(): int
    {
        return max(1, (int) $this->context->config()->get('min_label_length', 3));
    }

    public function maxLabelLength(): int
    {
        return max($this->minLabelLength(), (int) $this->context->config()->get('max_label_length', 32));
    }

    public function allowCustomDomain(): bool
    {
        $value = $this->context->config()->get('allow_custom_domain', false);

        return filter_var($value, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE) ?? (bool) $value;
    }

    public function customDomainMode(): string
    {
        $value = (string) $this->context->config()->get('custom_domain_mode', 'cname');
        $allowed = ['cname', 'nameserver', 'both'];

        return in_array($value, $allowed, true) ? $value : 'cname';
    }

    public function allowNameserverDelegation(): bool
    {
        $mode = $this->customDomainMode();

        return $mode === 'nameserver' || $mode === 'both';
    }

    public function allowCnameCustomDomain(): bool
    {
        if (!$this->allowCustomDomain()) {
            return false;
        }

        $mode = $this->customDomainMode();

        return $mode === 'cname' || $mode === 'both';
    }

    /**
     * @return string[]
     */
    public function reservedLabels(): array
    {
        $raw = $this->context->config()->get('reserved_labels', []);
        if (!is_array($raw)) {
            return $this->defaultReservedLabels();
        }

        $labels = [];
        foreach ($raw as $entry) {
            if (is_string($entry)) {
                $labels[] = strtolower(trim($entry));
            } elseif (is_array($entry) && isset($entry['label'])) {
                $labels[] = strtolower(trim((string) $entry['label']));
            }
        }
        $labels = array_values(array_filter($labels, fn (string $label) => $label !== ''));

        return $labels !== [] ? $labels : $this->defaultReservedLabels();
    }

    /**
     * @return PrimaryDomain[]
     */
    public function primaryDomains(): array
    {
        $defaultZoneId = $this->zoneId();
        $defaultDomain = $this->baseDomain();
        $domains = [
            new PrimaryDomain('default', $defaultDomain, $defaultZoneId, true),
        ];

        $raw = $this->context->config()->get('primary_domains', []);
        if (!is_array($raw)) {
            return $domains;
        }

        $seen = ['default' => true];
        foreach ($raw as $entry) {
            if (!is_array($entry)) {
                continue;
            }

            $domain = PrimaryDomain::fromConfigEntry($entry, $defaultZoneId, $defaultDomain);
            if (is_null($domain) || isset($seen[$domain->id])) {
                continue;
            }

            $seen[$domain->id] = true;
            $domains[] = $domain;
        }

        return $domains;
    }

    public function resolvePrimaryDomain(?string $domainId): PrimaryDomain
    {
        $id = $domainId !== null && $domainId !== '' ? $domainId : 'default';

        foreach ($this->primaryDomains() as $domain) {
            if ($domain->id === $id) {
                return $domain;
            }
        }

        foreach ($this->primaryDomains() as $domain) {
            if ($domain->id === 'default') {
                return $domain;
            }
        }

        return new PrimaryDomain('default', $this->baseDomain(), $this->zoneId(), true);
    }

    public function isPrimaryDomainConfigured(string $domainName): bool
    {
        $lower = strtolower(rtrim($domainName, '.'));

        foreach ($this->primaryDomains() as $domain) {
            if (strtolower($domain->domain) === $lower) {
                return true;
            }
        }

        return false;
    }

    /**
     * @return SrvProfile[]
     */
    public function srvProfiles(): array
    {
        $raw = $this->context->config()->get('srv_profiles', []);
        if (!is_array($raw)) {
            return [];
        }

        $profiles = [];
        foreach ($raw as $entry) {
            if (!is_array($entry)) {
                continue;
            }

            $profile = SrvProfile::fromConfigEntry($entry);
            if (!is_null($profile)) {
                $profiles[] = $profile;
            }
        }

        return $profiles;
    }

    /**
     * @return SrvProfile[]
     */
    public function autoProvisionProfiles(): array
    {
        return array_values(array_filter(
            $this->srvProfiles(),
            fn (SrvProfile $profile) => $profile->autoProvision
        ));
    }

    public function findProfile(string $id): ?SrvProfile
    {
        foreach ($this->srvProfiles() as $profile) {
            if ($profile->id === $id) {
                return $profile;
            }
        }

        return null;
    }

    /**
     * @return string[]
     */
    private function defaultReservedLabels(): array
    {
        return [
            'www', 'mail', 'admin', 'api', 'panel', 'ftp', 'ns1', 'ns2',
            '_acme-challenge', 'autodiscover', 'cpanel', 'webmail', 'smtp', 'imap',
        ];
    }

    private function requireString(string $key): string
    {
        $value = $this->optionalString($key);
        if ($value === '') {
            throw new PluginException(sprintf('DNS plugin config "%s" is not set.', $key));
        }

        return $value;
    }

    private function optionalString(string $key): string
    {
        $value = $this->context->config()->get($key);

        return is_string($value) ? trim($value) : '';
    }
}
