<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;

class ServerDnsState
{
    private const STATE_KEY = 'dns_state';

    /** Matches panel PluginSettingsStore::SERVER_SETTINGS_KEY */
    private const PLUGIN_SETTINGS_KEY = 'plugin_settings';

    public function __construct(
        private readonly PluginContext $context,
    ) {
    }

    /**
     * @return array<string, mixed>
     */
    public function all(int $serverId): array
    {
        $state = $this->context->data()->get('server', $serverId, self::STATE_KEY, []);

        return is_array($state) ? $this->normalize($state) : $this->emptyState();
    }

    public function save(int $serverId, array $state): void
    {
        $this->context->data()->set('server', $serverId, self::STATE_KEY, $this->normalize($state));
    }

    public function hostnameLabel(int $serverId): ?string
    {
        $label = $this->all($serverId)['hostname_label'];

        return is_string($label) && $label !== '' ? $label : null;
    }

    public function setHostnameLabel(int $serverId, string $label): void
    {
        $state = $this->all($serverId);
        $state['hostname_label'] = $label;
        $this->save($serverId, $state);
    }

    public function hostnameMode(int $serverId): string
    {
        return $this->all($serverId)['hostname_mode'];
    }

    public function setHostnameMode(int $serverId, string $mode): void
    {
        $state = $this->all($serverId);
        $state['hostname_mode'] = $mode;
        $this->save($serverId, $state);
    }

    public function primaryDomainId(int $serverId): string
    {
        return $this->all($serverId)['primary_domain'];
    }

    public function setPrimaryDomainId(int $serverId, string $domainId): void
    {
        $state = $this->all($serverId);
        $state['primary_domain'] = $domainId;
        $this->save($serverId, $state);
    }

    public function subdomainLocked(int $serverId): bool
    {
        return $this->all($serverId)['subdomain_locked'];
    }

    public function setSubdomainLocked(int $serverId, bool $locked): void
    {
        $state = $this->all($serverId);
        $state['subdomain_locked'] = $locked;
        $this->save($serverId, $state);
    }

    public function labelChangeCount(int $serverId): int
    {
        return $this->all($serverId)['label_change_count'];
    }

    public function recordLabelChange(int $serverId, int $periodHours = 168): void
    {
        $state = $this->all($serverId);
        $lastChange = $state['last_label_change_at'];
        if (is_string($lastChange) && $lastChange !== '') {
            $windowStart = now()->subHours($periodHours);
            if (now()->parse($lastChange)->lt($windowStart)) {
                $state['label_change_count'] = 0;
            }
        }

        $state['label_change_count'] = (int) $state['label_change_count'] + 1;
        $state['last_label_change_at'] = now()->toIso8601String();
        $this->save($serverId, $state);
    }

    public function lastLabelChangeAt(int $serverId): ?string
    {
        $value = $this->all($serverId)['last_label_change_at'];

        return is_string($value) && $value !== '' ? $value : null;
    }

    public function customDomain(int $serverId): ?string
    {
        $value = $this->all($serverId)['custom_domain'];

        return is_string($value) && $value !== '' ? $value : null;
    }

    public function setCustomDomain(int $serverId, ?string $domain): void
    {
        $state = $this->all($serverId);
        $state['custom_domain'] = $domain;
        $this->save($serverId, $state);
    }

    public function customDomainStatus(int $serverId): string
    {
        return $this->all($serverId)['custom_domain_status'];
    }

    public function setCustomDomainStatus(int $serverId, string $status): void
    {
        $state = $this->all($serverId);
        $state['custom_domain_status'] = $status;
        $this->save($serverId, $state);
    }

    public function customDomainToken(int $serverId): ?string
    {
        $value = $this->all($serverId)['custom_domain_token'];

        return is_string($value) && $value !== '' ? $value : null;
    }

    public function setCustomDomainToken(int $serverId, ?string $token): void
    {
        $state = $this->all($serverId);
        $state['custom_domain_token'] = $token;
        $this->save($serverId, $state);
    }

    public function customDomainTokenExpiresAt(int $serverId): ?string
    {
        $value = $this->all($serverId)['custom_domain_token_expires_at'];

        return is_string($value) && $value !== '' ? $value : null;
    }

    public function setCustomDomainTokenExpiresAt(int $serverId, ?string $expiresAt): void
    {
        $state = $this->all($serverId);
        $state['custom_domain_token_expires_at'] = $expiresAt;
        $this->save($serverId, $state);
    }

    public function nameserverDomain(int $serverId): ?string
    {
        $value = $this->all($serverId)['nameserver_domain'];

        return is_string($value) && $value !== '' ? $value : null;
    }

    public function setNameserverDomain(int $serverId, ?string $domain): void
    {
        $state = $this->all($serverId);
        $state['nameserver_domain'] = $domain;
        $this->save($serverId, $state);
    }

    public function nameserverStatus(int $serverId): string
    {
        return $this->all($serverId)['nameserver_status'];
    }

    public function setNameserverStatus(int $serverId, string $status): void
    {
        $state = $this->all($serverId);
        $state['nameserver_status'] = $status;
        $this->save($serverId, $state);
    }

    public function nameserverZoneId(int $serverId): ?string
    {
        $value = $this->all($serverId)['nameserver_zone_id'];

        return is_string($value) && $value !== '' ? $value : null;
    }

    public function setNameserverZoneId(int $serverId, ?string $zoneId): void
    {
        $state = $this->all($serverId);
        $state['nameserver_zone_id'] = $zoneId;
        $this->save($serverId, $state);
    }

    /**
     * @return string[]
     */
    public function subdomainCheckLog(int $serverId): array
    {
        return $this->all($serverId)['subdomain_check_log'];
    }

    public function appendSubdomainCheck(int $serverId): void
    {
        $state = $this->all($serverId);
        $log = $state['subdomain_check_log'];
        $log[] = now()->toIso8601String();
        $cutoff = now()->subMinute()->toIso8601String();
        $state['subdomain_check_log'] = array_values(array_filter(
            $log,
            fn (string $timestamp) => $timestamp >= $cutoff
        ));
        $this->save($serverId, $state);
    }

    /**
     * @return string[]
     */
    public function srvProfileIds(int $serverId): array
    {
        $settings = $this->pluginSettings($serverId);
        if (array_key_exists('enabled_profile_ids', $settings) && is_array($settings['enabled_profile_ids'])) {
            return array_values(array_map('strval', $settings['enabled_profile_ids']));
        }

        return $this->all($serverId)['srv_profile_ids'];
    }

    /**
     * @param string[] $ids
     */
    public function setSrvProfileIds(int $serverId, array $ids): void
    {
        $ids = array_values(array_unique(array_map('strval', $ids)));

        $state = $this->all($serverId);
        $state['srv_profile_ids'] = $ids;
        $this->save($serverId, $state);

        $settings = $this->pluginSettings($serverId);
        $settings['enabled_profile_ids'] = $ids;
        $this->writePluginSettings($serverId, $settings);
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function dnsRecords(int $serverId): array
    {
        return $this->all($serverId)['dns_records'];
    }

    public function findRecord(int $serverId, string $recordId): ?array
    {
        foreach ($this->dnsRecords($serverId) as $record) {
            if ($this->recordMatchesId($record, $recordId)) {
                return $record;
            }
        }

        return null;
    }

    public function findRecordByNameAndType(int $serverId, string $name, string $type): ?array
    {
        $needleName = strtolower(rtrim($name, '.'));
        $needleType = strtoupper($type);

        foreach ($this->dnsRecords($serverId) as $record) {
            $recordName = strtolower(rtrim((string) ($record['name'] ?? ''), '.'));
            $recordType = strtoupper((string) ($record['type'] ?? ''));

            if ($recordName === $needleName && $recordType === $needleType) {
                return $record;
            }
        }

        return null;
    }

    /**
     * @param array<string, mixed> $record
     */
    public function recordKey(array $record): string
    {
        $id = (string) ($record['record_id'] ?? $record['cloudflare_id'] ?? '');

        return $id;
    }

    /**
     * @param array<string, mixed> $record
     */
    private function recordMatchesId(array $record, string $recordId): bool
    {
        if ($recordId === '') {
            return false;
        }

        return ($record['cloudflare_id'] ?? '') === $recordId
            || ($record['record_id'] ?? '') === $recordId;
    }

    public function findRecordByProfile(int $serverId, string $profileId): ?array
    {
        foreach ($this->dnsRecords($serverId) as $record) {
            if (($record['profile_id'] ?? null) === $profileId && ($record['type'] ?? '') === 'SRV') {
                return $record;
            }
        }

        return null;
    }

    public function upsertRecord(int $serverId, array $record): void
    {
        $state = $this->all($serverId);
        $records = $state['dns_records'];
        $found = false;

        foreach ($records as $index => $existing) {
            $existingKey = (string) ($existing['record_id'] ?? $existing['cloudflare_id'] ?? '');
            $incomingKey = (string) ($record['record_id'] ?? $record['cloudflare_id'] ?? '');
            if ($existingKey !== '' && $incomingKey !== '' && $existingKey === $incomingKey) {
                $records[$index] = array_merge($existing, $record);
                $found = true;
                break;
            }
        }

        if (!$found) {
            $records[] = $record;
        }

        $state['dns_records'] = $records;
        $this->save($serverId, $state);
    }

    public function removeRecord(int $serverId, string $recordId): void
    {
        $state = $this->all($serverId);
        $state['dns_records'] = array_values(array_filter(
            $state['dns_records'],
            fn (array $record) => !$this->recordMatchesId($record, $recordId)
        ));
        $this->save($serverId, $state);
    }

    public function removeRecordsByProfile(int $serverId, string $profileId): void
    {
        $state = $this->all($serverId);
        $state['dns_records'] = array_values(array_filter(
            $state['dns_records'],
            fn (array $record) => ($record['profile_id'] ?? null) !== $profileId
        ));
        $this->save($serverId, $state);
    }

    public function aRecordId(int $serverId): ?string
    {
        $id = $this->all($serverId)['a_record_id'];

        return is_string($id) && $id !== '' ? $id : null;
    }

    public function aRecordName(int $serverId): ?string
    {
        $name = $this->all($serverId)['a_record_name'];

        return is_string($name) && $name !== '' ? $name : null;
    }

    public function setARecord(int $serverId, string $cloudflareId, string $name): void
    {
        $state = $this->all($serverId);
        $state['a_record_id'] = $cloudflareId;
        $state['a_record_name'] = $name;
        $this->save($serverId, $state);
    }

    public function initializeHostname(
        int $serverId,
        string $label,
        string $primaryDomainId,
        string $mode = 'auto',
    ): void {
        $state = $this->all($serverId);
        if ($state['hostname_label'] === null) {
            $state['hostname_label'] = $label;
            $state['hostname_mode'] = $mode;
            $state['primary_domain'] = $primaryDomainId;
            $this->save($serverId, $state);
        }
    }

    public function clear(int $serverId): void
    {
        $this->context->data()->delete('server', $serverId, self::STATE_KEY);
    }

    /**
     * @return array<string, mixed>
     */
    private function pluginSettings(int $serverId): array
    {
        $settings = $this->context->data()->get('server', $serverId, self::PLUGIN_SETTINGS_KEY, []);

        return is_array($settings) ? $settings : [];
    }

    /**
     * @param array<string, mixed> $settings
     */
    private function writePluginSettings(int $serverId, array $settings): void
    {
        $this->context->data()->set('server', $serverId, self::PLUGIN_SETTINGS_KEY, $settings);
    }

    /**
     * @return array<string, mixed>
     */
    private function emptyState(): array
    {
        return [
            'srv_profile_ids' => [],
            'a_record_id' => null,
            'a_record_name' => null,
            'dns_records' => [],
            'hostname_label' => null,
            'hostname_mode' => 'auto',
            'primary_domain' => 'default',
            'subdomain_locked' => false,
            'label_change_count' => 0,
            'last_label_change_at' => null,
            'custom_domain' => null,
            'custom_domain_status' => 'none',
            'custom_domain_token' => null,
            'custom_domain_token_expires_at' => null,
            'nameserver_domain' => null,
            'nameserver_status' => 'none',
            'nameserver_zone_id' => null,
            'subdomain_check_log' => [],
        ];
    }

    /**
     * @param array<string, mixed> $state
     * @return array<string, mixed>
     */
    private function normalize(array $state): array
    {
        $mode = (string) ($state['hostname_mode'] ?? 'auto');
        if (!in_array($mode, ['auto', 'vanity', 'custom', 'locked'], true)) {
            $mode = 'auto';
        }

        $customStatus = (string) ($state['custom_domain_status'] ?? 'none');
        if (!in_array($customStatus, ['none', 'pending', 'verified', 'failed'], true)) {
            $customStatus = 'none';
        }

        $nsStatus = (string) ($state['nameserver_status'] ?? 'none');
        if (!in_array($nsStatus, ['none', 'pending', 'pending_approval', 'active', 'failed'], true)) {
            $nsStatus = 'none';
        }

        return [
            'srv_profile_ids' => array_values(array_map(
                'strval',
                is_array($state['srv_profile_ids'] ?? null) ? $state['srv_profile_ids'] : []
            )),
            'a_record_id' => isset($state['a_record_id']) ? (string) $state['a_record_id'] : null,
            'a_record_name' => isset($state['a_record_name']) ? (string) $state['a_record_name'] : null,
            'dns_records' => is_array($state['dns_records'] ?? null) ? array_values($state['dns_records']) : [],
            'hostname_label' => isset($state['hostname_label']) ? (string) $state['hostname_label'] : null,
            'hostname_mode' => $mode,
            'primary_domain' => isset($state['primary_domain']) ? (string) $state['primary_domain'] : 'default',
            'subdomain_locked' => filter_var($state['subdomain_locked'] ?? false, FILTER_VALIDATE_BOOLEAN),
            'label_change_count' => max(0, (int) ($state['label_change_count'] ?? 0)),
            'last_label_change_at' => isset($state['last_label_change_at']) ? (string) $state['last_label_change_at'] : null,
            'custom_domain' => isset($state['custom_domain']) ? (string) $state['custom_domain'] : null,
            'custom_domain_status' => $customStatus,
            'custom_domain_token' => isset($state['custom_domain_token']) ? (string) $state['custom_domain_token'] : null,
            'custom_domain_token_expires_at' => isset($state['custom_domain_token_expires_at'])
                ? (string) $state['custom_domain_token_expires_at']
                : null,
            'nameserver_domain' => isset($state['nameserver_domain']) ? (string) $state['nameserver_domain'] : null,
            'nameserver_status' => $nsStatus,
            'nameserver_zone_id' => isset($state['nameserver_zone_id']) ? (string) $state['nameserver_zone_id'] : null,
            'subdomain_check_log' => is_array($state['subdomain_check_log'] ?? null)
                ? array_values(array_map('strval', $state['subdomain_check_log']))
                : [],
        ];
    }
}
