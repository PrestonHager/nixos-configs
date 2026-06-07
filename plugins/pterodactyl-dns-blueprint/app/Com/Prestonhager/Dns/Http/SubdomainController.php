<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\RecordName;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ServerDnsState;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionData;
use Pterodactyl\Models\Server;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpResponse;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class SubdomainController
{
    public function show(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);

        return PluginHttpResponse::json([
            'object' => 'subdomain',
            'attributes' => $this->buildAttributes($context, $request, $serverId, $server),
        ]);
    }

    public function update(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);
        $config = Services::config($context);
        $validator = Services::subdomainValidator($context);
        $manager = Services::hostnameManager($context);
        $state = Services::state($context);

        $label = (string) ($request->body['label'] ?? '');
        if ($label === '') {
            throw new PluginException('Request body must include a "label".');
        }

        $primaryDomainId = (string) ($request->body['primary_domain'] ?? $state->primaryDomainId($serverId));
        $primaryDomain = $config->resolvePrimaryDomain($primaryDomainId);

        $validator->ensureClientMayChange($request, $serverId, $server->ownerId);
        $validator->ensurePrimaryDomainSelectable($primaryDomain, $request, $server->ownerId);
        $validator->validateLabelFormat($label);
        $validator->ensureLabelAvailable($label, $primaryDomain, $serverId);

        $locked = filter_var($request->body['subdomain_locked'] ?? false, FILTER_VALIDATE_BOOLEAN);
        if (Services::dnsPolicy($context)->canBypassSubdomainPolicy($request, $server->ownerId)) {
            $state->setSubdomainLocked($serverId, $locked);
        }

        $countAsChange = !Services::dnsPolicy($context)->canBypassSubdomainPolicy($request, $server->ownerId);
        $mode = Services::dnsPolicy($context)->canBypassSubdomainPolicy($request, $server->ownerId) ? 'vanity' : 'vanity';
        $result = $manager->applyLabelChange($serverId, $server, $label, $primaryDomain->id, $countAsChange, $mode);

        return PluginHttpResponse::json([
            'object' => 'subdomain',
            'attributes' => array_merge(
                $this->buildAttributes($context, $request, $serverId, $server),
                $result
            ),
        ]);
    }

    public function check(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $config = Services::config($context);
        $validator = Services::subdomainValidator($context);
        $registry = Services::hostnameRegistry($context);

        $validator->ensureCheckRateLimit($serverId);

        $label = (string) ($request->query['label'] ?? '');
        $primaryDomainId = (string) ($request->query['domain'] ?? $request->query['primary_domain'] ?? 'default');

        if ($label === '') {
            throw new PluginException('Query parameter "label" is required.');
        }

        $validator->validateLabelFormat($label);
        $primaryDomain = $config->resolvePrimaryDomain($primaryDomainId);
        $available = $registry->isLabelAvailable($label, $primaryDomain, $serverId);

        return PluginHttpResponse::json([
            'object' => 'subdomain_check',
            'attributes' => [
                'label' => RecordName::normalizeLabel($label),
                'primary_domain' => $primaryDomain->id,
                'fqdn' => RecordName::fqdn(RecordName::normalizeLabel($label), $primaryDomain->domain),
                'available' => $available,
            ],
        ]);
    }

    public function regenerate(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);
        $policy = Services::dnsPolicy($context);

        if (!$policy->canBypassSubdomainPolicy($request, $server->ownerId)) {
            throw new PluginException('Only administrators can regenerate hostnames.', 403);
        }

        $result = Services::hostnameManager($context)->regenerate($serverId, $server);

        $context->activity()->log('subdomain-regenerated', [
            'server_id' => $serverId,
            'server_uuid' => $server->uuid,
            'label' => $result['hostname_label'],
        ]);

        return PluginHttpResponse::json([
            'object' => 'subdomain',
            'attributes' => array_merge(
                $this->buildAttributes($context, $request, $serverId, $server),
                $result
            ),
        ]);
    }

    public function showCustomDomain(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $config = Services::config($context);
        $state = Services::state($context);

        if (!$config->allowCnameCustomDomain()) {
            throw new PluginException('Custom domains are not enabled.', 403);
        }

        $primaryDomain = $config->resolvePrimaryDomain($state->primaryDomainId($serverId));
        $label = $state->hostnameLabel($serverId) ?? 'server';
        $cnameTarget = RecordName::fqdn($label, $primaryDomain->domain);

        return PluginHttpResponse::json([
            'object' => 'custom_domain',
            'attributes' => $this->customDomainAttributes($state, $serverId, $cnameTarget),
        ]);
    }

    public function updateCustomDomain(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);
        $config = Services::config($context);
        $state = Services::state($context);
        $validator = Services::subdomainValidator($context);

        if (!$config->allowCnameCustomDomain()) {
            throw new PluginException('Custom domains are not enabled.', 403);
        }

        $validator->ensureClientMayChange($request, $serverId, $server->ownerId);

        $domain = strtolower(rtrim(trim((string) ($request->body['domain'] ?? '')), '.'));
        if ($domain === '' || !str_contains($domain, '.')) {
            throw new PluginException('A valid custom domain is required.');
        }

        if ($config->isPrimaryDomainConfigured($domain)) {
            throw new PluginException('Use the hostname picker for hosted primary domains.', 422);
        }

        $token = hash('sha256', $server->uuid . '|' . $domain . '|' . bin2hex(random_bytes(16)));
        $expiresAt = now()->addHours(72)->toIso8601String();

        $state->setCustomDomain($serverId, $domain);
        $state->setCustomDomainStatus($serverId, 'pending');
        $state->setCustomDomainToken($serverId, $token);
        $state->setCustomDomainTokenExpiresAt($serverId, $expiresAt);

        $primaryDomain = $config->resolvePrimaryDomain($state->primaryDomainId($serverId));
        $label = $state->hostnameLabel($serverId) ?? 'server';
        $cnameTarget = RecordName::fqdn($label, $primaryDomain->domain);

        return PluginHttpResponse::json([
            'object' => 'custom_domain',
            'attributes' => $this->customDomainAttributes($state, $serverId, $cnameTarget),
        ]);
    }

    public function verifyCustomDomain(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);
        $config = Services::config($context);
        $state = Services::state($context);
        $lookup = Services::dnsLookup($context);

        if (!$config->allowCnameCustomDomain()) {
            throw new PluginException('Custom domains are not enabled.', 403);
        }

        $domain = $state->customDomain($serverId);
        $token = $state->customDomainToken($serverId);
        $expiresAt = $state->customDomainTokenExpiresAt($serverId);

        if ($domain === null || $token === null) {
            throw new PluginException('No custom domain pending verification.');
        }

        if ($expiresAt !== null && now()->greaterThan(now()->parse($expiresAt))) {
            $state->setCustomDomainStatus($serverId, 'failed');
            throw new PluginException('Verification token expired. Request a new custom domain.');
        }

        $primaryDomain = $config->resolvePrimaryDomain($state->primaryDomainId($serverId));
        $label = $state->hostnameLabel($serverId) ?? 'server';
        $cnameTarget = RecordName::fqdn($label, $primaryDomain->domain);

        if (!$lookup->verifyCustomDomain($domain, $token, $cnameTarget)) {
            $state->setCustomDomainStatus($serverId, 'failed');
            throw new PluginException('DNS verification failed. Ensure the TXT or CNAME record is published.');
        }

        $state->setCustomDomainStatus($serverId, 'verified');
        $state->setHostnameMode($serverId, 'custom');
        $state->setCustomDomainToken($serverId, null);
        $state->setCustomDomainTokenExpiresAt($serverId, null);

        $context->activity()->log('custom-domain-verified', [
            'server_id' => $serverId,
            'server_uuid' => $server->uuid,
            'custom_domain' => $domain,
        ]);

        return PluginHttpResponse::json([
            'object' => 'custom_domain',
            'attributes' => $this->customDomainAttributes($state, $serverId, $cnameTarget),
        ]);
    }

    public function showNameserver(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $config = Services::config($context);
        $state = Services::state($context);

        if (!$config->allowNameserverDelegation()) {
            throw new PluginException('Nameserver delegation is not enabled.', 403);
        }

        return PluginHttpResponse::json([
            'object' => 'nameserver_delegation',
            'attributes' => $this->nameserverAttributes($context, $state, $serverId),
        ]);
    }

    public function updateNameserver(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);
        $config = Services::config($context);
        $state = Services::state($context);
        $validator = Services::subdomainValidator($context);

        if (!$config->allowNameserverDelegation()) {
            throw new PluginException('Nameserver delegation is not enabled.', 403);
        }

        $validator->ensureClientMayChange($request, $serverId, $server->ownerId);

        $domain = strtolower(rtrim(trim((string) ($request->body['domain'] ?? '')), '.'));
        if ($domain === '' || !str_contains($domain, '.')) {
            throw new PluginException('A valid domain is required for nameserver delegation.');
        }

        if ($config->isPrimaryDomainConfigured($domain)) {
            throw new PluginException('That domain is already managed by this host.', 422);
        }

        $state->setNameserverDomain($serverId, $domain);
        $state->setNameserverStatus($serverId, 'pending_approval');
        $state->setNameserverZoneId($serverId, null);

        $context->activity()->log('nameserver-delegation-requested', [
            'server_id' => $serverId,
            'server_uuid' => $server->uuid,
            'domain' => $domain,
        ]);

        return PluginHttpResponse::json([
            'object' => 'nameserver_delegation',
            'attributes' => $this->nameserverAttributes($context, $state, $serverId),
        ]);
    }

    public function verifyNameserver(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->requireServerId($request);
        $config = Services::config($context);
        $state = Services::state($context);
        $client = Services::client($context);

        if (!$config->allowNameserverDelegation()) {
            throw new PluginException('Nameserver delegation is not enabled.', 403);
        }

        $domain = $state->nameserverDomain($serverId);
        if ($domain === null) {
            throw new PluginException('No nameserver delegation is configured.');
        }

        if ($state->nameserverStatus($serverId) !== 'active') {
            throw new PluginException('Nameserver delegation must be approved and active before verification.', 422);
        }

        $zoneId = $state->nameserverZoneId($serverId);
        if ($zoneId === null) {
            $response = $client->listZones(['name' => $domain, 'status' => 'active']);
            $results = $response['result'] ?? [];
            if (!is_array($results) || $results === []) {
                $state->setNameserverStatus($serverId, 'pending');
                throw new PluginException('Zone is not active yet. Update nameservers at your registrar.');
            }

            $zoneId = (string) ($results[0]['id'] ?? '');
            if ($zoneId === '') {
                throw new PluginException('Could not resolve Cloudflare zone for this domain.');
            }

            $state->setNameserverZoneId($serverId, $zoneId);
        }

        $state->setHostnameMode($serverId, 'custom');

        $context->activity()->log('nameserver-delegation-verified', [
            'server_id' => $serverId,
            'domain' => $domain,
            'zone_id' => $zoneId,
        ]);

        return PluginHttpResponse::json([
            'object' => 'nameserver_delegation',
            'attributes' => $this->nameserverAttributes($context, $state, $serverId),
        ]);
    }

    public function pendingNameserverDelegations(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $pending = [];
        $records = DnsExtensionData::query()
            ->where('scope', 'server')
            ->where('key', 'dns_state')
            ->get();

        foreach ($records as $record) {
            $value = $record->value;
            if (!is_array($value)) {
                continue;
            }

            if (($value['nameserver_status'] ?? 'none') !== 'pending_approval') {
                continue;
            }

            $server = $context->servers()->find((int) $record->subject_id);
            $pending[] = [
                'server_id' => (int) $record->subject_id,
                'server_uuid' => $server->uuid,
                'server_name' => $server->name,
                'domain' => $value['nameserver_domain'] ?? null,
            ];
        }

        return PluginHttpResponse::json([
            'object' => 'list',
            'data' => $pending,
        ]);
    }

    public function approveNameserverDelegation(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        $serverId = $this->resolveServerIdFromRoute($request);

        $state = Services::state($context);
        $client = Services::client($context);
        $domain = $state->nameserverDomain($serverId);

        if ($domain === null || $state->nameserverStatus($serverId) !== 'pending_approval') {
            throw new PluginException('No pending nameserver delegation for this server.');
        }

        $response = $client->listZones(['name' => $domain]);
        $results = $response['result'] ?? [];
        $zoneId = null;
        $nameservers = [];

        if (is_array($results) && $results !== []) {
            $zone = $results[0];
            $zoneId = (string) ($zone['id'] ?? '');
            $nameservers = is_array($zone['name_servers'] ?? null) ? $zone['name_servers'] : [];
        }

        $state->setNameserverZoneId($serverId, $zoneId);
        $state->setNameserverStatus($serverId, $zoneId !== null && $nameservers !== [] ? 'active' : 'pending');

        $context->activity()->log('nameserver-delegation-approved', [
            'server_id' => $serverId,
            'domain' => $domain,
            'zone_id' => $zoneId,
        ]);

        return PluginHttpResponse::json([
            'object' => 'nameserver_delegation',
            'attributes' => array_merge(
                $this->nameserverAttributes($context, $state, $serverId),
                ['approved' => true]
            ),
        ]);
    }

    /**
     * @return array<string, mixed>
     */
    private function buildAttributes(
        PluginContext $context,
        PluginHttpRequest $request,
        int $serverId,
        $server,
    ): array {
        $config = Services::config($context);
        $state = Services::state($context);
        $manager = Services::hostnameManager($context);

        $label = $manager->ensureInitialHostname($serverId, $server);
        $primaryDomain = $config->resolvePrimaryDomain($state->primaryDomainId($serverId));
        $fqdn = RecordName::fqdn($label, $primaryDomain->domain);
        $network = $context->servers()->getNetworkSummary($serverId);
        $primary = null;
        foreach ($network->allocations as $allocation) {
            if ($allocation->isPrimary) {
                $primary = $allocation;
                break;
            }
        }

        $target = '';
        $port = 25565;
        if (!is_null($primary)) {
            $target = ($primary->ipAlias !== null && $primary->ipAlias !== '')
                ? $primary->ipAlias
                : $primary->ip;
            $port = $primary->port;
        }

        $policy = Services::subdomainValidator($context)->clientPolicySummary($request, $serverId, $server->ownerId);

        return [
            'hostname_label' => $label,
            'hostname_mode' => $state->hostnameMode($serverId),
            'fqdn' => $fqdn,
            'primary_domain' => $primaryDomain->id,
            'primary_domains' => array_map(
                fn ($domain) => $domain->toArray(false),
                array_values(array_filter(
                    $config->primaryDomains(),
                    fn ($domain) => $domain->clientSelectable
                        || Services::dnsPolicy($context)->canBypassSubdomainPolicy($request, $server->ownerId)
                ))
            ),
            'subdomain_locked' => $state->subdomainLocked($serverId),
            'label_change_count' => $state->labelChangeCount($serverId),
            'last_label_change_at' => $state->lastLabelChangeAt($serverId),
            'policy' => $policy,
            'connection' => [
                'host' => $fqdn,
                'port' => $port,
                'ip' => $target,
                'address' => $fqdn . ':' . $port,
            ],
            'custom_domain_enabled' => $config->allowCnameCustomDomain(),
            'nameserver_delegation_enabled' => $config->allowNameserverDelegation(),
        ];
    }

    /**
     * @return array<string, mixed>
     */
    private function customDomainAttributes(ServerDnsState $state, int $serverId, string $cnameTarget): array
    {
        $domain = $state->customDomain($serverId);
        $token = $state->customDomainToken($serverId);

        return [
            'custom_domain' => $domain,
            'custom_domain_status' => $state->customDomainStatus($serverId),
            'verification' => $domain !== null && $token !== null ? [
                'txt_host' => '_dns-verify.' . $domain,
                'txt_value' => $token,
                'cname_host' => $domain,
                'cname_target' => $cnameTarget,
                'expires_at' => $state->customDomainTokenExpiresAt($serverId),
            ] : null,
        ];
    }

    /**
     * @return array<string, mixed>
     */
    private function nameserverAttributes(PluginContext $context, ServerDnsState $state, int $serverId): array
    {
        $domain = $state->nameserverDomain($serverId);
        $nameservers = [];

        if ($domain !== null && $state->nameserverZoneId($serverId) !== null) {
            $response = Services::client($context)->listZones(['name' => $domain]);
            $results = $response['result'] ?? [];
            if (is_array($results) && $results !== []) {
                $nameservers = is_array($results[0]['name_servers'] ?? null) ? $results[0]['name_servers'] : [];
            }
        }

        return [
            'nameserver_domain' => $domain,
            'nameserver_status' => $state->nameserverStatus($serverId),
            'nameserver_zone_id' => $state->nameserverZoneId($serverId),
            'nameservers' => $nameservers,
        ];
    }

    private function resolveServerIdFromRoute(PluginHttpRequest $request): int
    {
        $serverParam = (string) $request->route('server', '');
        if ($serverParam === '') {
            throw new PluginException('Server id is required.');
        }

        if (ctype_digit($serverParam)) {
            $server = Server::query()->find((int) $serverParam);
        } else {
            $server = Server::query()->where('uuid', $serverParam)->first();
        }

        if (is_null($server)) {
            throw new PluginException('Server was not found.');
        }

        return $server->id;
    }

    private function requireServerId(PluginHttpRequest $request): int
    {
        if (is_null($request->serverId)) {
            throw new PluginException('Server context is required.');
        }

        return $request->serverId;
    }
}
