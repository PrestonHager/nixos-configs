<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\SrvProfile;

class SrvRecordMatcher
{
    public function __construct(
        private readonly Client $client,
    ) {
    }

    /**
     * @param array<int, array<string, mixed>> $localRecords
     * @param string[] $targetCandidates
     * @return array<string, mixed>|null
     */
    public function findExisting(
        SrvProfile $profile,
        string $expectedSrvName,
        int $port,
        array $targetCandidates,
        array $localRecords,
        string $zoneId,
    ): ?array {
        foreach ($localRecords as $record) {
            if (($record['profile_id'] ?? null) === $profile->id && ($record['type'] ?? '') === 'SRV') {
                return $record;
            }
        }

        $byName = $this->findInCloudflareByName($expectedSrvName, $zoneId);
        if (!is_null($byName)) {
            return $this->mapCloudflareRecord($byName, $profile, $port);
        }

        $byHeuristic = $this->findInCloudflareByPortAndTarget($port, $targetCandidates, $zoneId, $profile);
        if (!is_null($byHeuristic)) {
            return $this->mapCloudflareRecord($byHeuristic, $profile, $port);
        }

        return null;
    }

    /**
     * @param string[] $targetCandidates
     * @return array<string, mixed>|null
     */
    private function findInCloudflareByName(string $name, string $zoneId): ?array
    {
        $records = $this->client->listRecords($zoneId, [
            'type' => 'SRV',
            'name' => $name,
        ]);

        foreach ($records as $record) {
            if (strcasecmp((string) ($record['name'] ?? ''), $name) === 0) {
                return $record;
            }
        }

        return null;
    }

    /**
     * @param string[] $targetCandidates
     * @return array<string, mixed>|null
     */
    private function findInCloudflareByPortAndTarget(
        int $port,
        array $targetCandidates,
        string $zoneId,
        SrvProfile $profile,
    ): ?array {
        $normalizedTargets = array_map(
            fn (string $target) => strtolower(rtrim($target, '.')),
            array_filter($targetCandidates, fn ($t) => is_string($t) && $t !== '')
        );

        if ($normalizedTargets === []) {
            return null;
        }

        $records = $this->client->listRecords($zoneId, ['type' => 'SRV']);

        foreach ($records as $record) {
            $data = $record['data'] ?? null;
            if (!is_array($data)) {
                continue;
            }

            $recordPort = (int) ($data['port'] ?? 0);
            if ($recordPort !== $port) {
                continue;
            }

            $recordTarget = strtolower(rtrim((string) ($data['target'] ?? ''), '.'));
            if (!in_array($recordTarget, $normalizedTargets, true)) {
                continue;
            }

            $service = (string) ($data['service'] ?? '');
            $proto = (string) ($data['proto'] ?? '');
            if ($service !== '' && $proto !== '' && !$this->matchesProfileService($record, $profile)) {
                continue;
            }

            return $record;
        }

        return null;
    }

    private function matchesProfileService(array $record, SrvProfile $profile): bool
    {
        $data = $record['data'] ?? [];
        if (!is_array($data)) {
            return false;
        }

        $service = (string) ($data['service'] ?? '');
        $proto = (string) ($data['proto'] ?? '');

        return strcasecmp($service, $profile->service) === 0
            && strcasecmp($proto, $profile->proto) === 0;
    }

    /**
     * @param array<string, mixed> $cloudflareRecord
     * @return array<string, mixed>
     */
    private function mapCloudflareRecord(array $cloudflareRecord, SrvProfile $profile, int $port): array
    {
        $data = $cloudflareRecord['data'] ?? [];

        return [
            'cloudflare_id' => (string) ($cloudflareRecord['id'] ?? ''),
            'type' => 'SRV',
            'name' => (string) ($cloudflareRecord['name'] ?? ''),
            'data' => is_array($data) ? $data : null,
            'profile_id' => $profile->id,
            'service' => $profile->service,
            'proto' => $profile->proto,
            'port' => is_array($data) ? (int) ($data['port'] ?? $port) : $port,
            'label' => $profile->label,
        ];
    }
}
