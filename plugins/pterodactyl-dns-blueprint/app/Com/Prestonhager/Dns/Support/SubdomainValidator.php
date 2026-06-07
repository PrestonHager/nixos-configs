<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class SubdomainValidator
{
    public function __construct(
        private readonly Config $config,
        private readonly DnsPolicy $policy,
        private readonly HostnameRegistry $registry,
        private readonly ServerDnsState $state,
    ) {
    }

    public function validateLabelFormat(string $label): void
    {
        $label = RecordName::normalizeLabel($label);

        if (!RecordName::isValidLabel($label, $this->config->minLabelLength(), $this->config->maxLabelLength())) {
            throw new PluginException(sprintf(
                'Invalid hostname label. Use %d–%d lowercase letters, numbers, and hyphens (not at the start or end).',
                $this->config->minLabelLength(),
                $this->config->maxLabelLength()
            ));
        }

        if (in_array($label, $this->config->reservedLabels(), true)) {
            throw new PluginException('That hostname label is reserved and cannot be used.');
        }
    }

    public function ensureClientMayChange(
        PluginHttpRequest $request,
        int $serverId,
        int $ownerId,
    ): void {
        if ($this->policy->canBypassSubdomainPolicy($request, $ownerId)) {
            return;
        }

        if ($this->state->subdomainLocked($serverId)) {
            throw new PluginException('This hostname is locked by an administrator.', 403);
        }

        $policy = $this->config->clientSubdomainPolicy();

        if ($policy === 'never') {
            throw new PluginException('Hostname changes are disabled for clients.', 403);
        }

        if ($policy === 'once_on_create' && $this->state->labelChangeCount($serverId) > 0) {
            throw new PluginException('Hostname can only be changed once during initial setup.', 403);
        }

        if ($policy === 'limited') {
            $this->ensureWithinChangeLimit($serverId);
        }
    }

    public function ensureCheckRateLimit(int $serverId): void
    {
        $log = $this->state->subdomainCheckLog($serverId);
        if (count($log) >= 10) {
            throw new PluginException('Too many availability checks. Try again in a minute.', 429);
        }

        $this->state->appendSubdomainCheck($serverId);
    }

    public function ensureLabelAvailable(
        string $label,
        PrimaryDomain $primaryDomain,
        int $serverId,
    ): void {
        if (!$this->registry->isLabelAvailable($label, $primaryDomain, $serverId)) {
            throw new PluginException('That hostname is already in use.', 409);
        }
    }

    public function ensurePrimaryDomainSelectable(PrimaryDomain $primaryDomain, PluginHttpRequest $request, int $ownerId): void
    {
        if ($this->policy->canBypassSubdomainPolicy($request, $ownerId)) {
            return;
        }

        if (!$primaryDomain->clientSelectable) {
            throw new PluginException('That primary domain is not available for client selection.', 403);
        }
    }

    /**
     * @return array{can_update: bool, changes_remaining: int|null, policy: string}
     */
    public function clientPolicySummary(PluginHttpRequest $request, int $serverId, int $ownerId): array
    {
        if ($this->policy->canBypassSubdomainPolicy($request, $ownerId)) {
            return [
                'can_update' => true,
                'changes_remaining' => null,
                'policy' => 'admin',
            ];
        }

        if ($this->state->subdomainLocked($serverId)) {
            return [
                'can_update' => false,
                'changes_remaining' => 0,
                'policy' => $this->config->clientSubdomainPolicy(),
            ];
        }

        $policy = $this->config->clientSubdomainPolicy();

        return match ($policy) {
            'always' => [
                'can_update' => true,
                'changes_remaining' => null,
                'policy' => $policy,
            ],
            'once_on_create' => [
                'can_update' => $this->state->labelChangeCount($serverId) === 0,
                'changes_remaining' => $this->state->labelChangeCount($serverId) === 0 ? 1 : 0,
                'policy' => $policy,
            ],
            'limited' => [
                'can_update' => $this->remainingChanges($serverId) > 0,
                'changes_remaining' => $this->remainingChanges($serverId),
                'policy' => $policy,
            ],
            default => [
                'can_update' => false,
                'changes_remaining' => 0,
                'policy' => $policy,
            ],
        };
    }

    private function ensureWithinChangeLimit(int $serverId): void
    {
        if ($this->remainingChanges($serverId) <= 0) {
            throw new PluginException('Hostname change limit reached for this period.', 429);
        }
    }

    private function remainingChanges(int $serverId): int
    {
        $limit = $this->config->clientChangeLimit();
        if ($limit <= 0) {
            return 0;
        }

        $periodHours = $this->config->clientChangePeriodHours();
        $lastChange = $this->state->lastLabelChangeAt($serverId);
        $count = $this->state->labelChangeCount($serverId);

        if ($lastChange === null) {
            return $limit;
        }

        $windowStart = now()->subHours($periodHours);
        if (now()->parse($lastChange)->lt($windowStart)) {
            return $limit;
        }

        return max(0, $limit - $count);
    }
}
