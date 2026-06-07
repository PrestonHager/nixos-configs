<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Cloudflare;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class Client
{
    private const BASE = 'https://api.cloudflare.com/client/v4';

    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
    ) {
    }

    /**
     * @param array<string, mixed> $query
     * @return array<string, mixed>
     */
    public function listZones(array $query = []): array
    {
        $queryString = $query !== [] ? '?' . http_build_query($query) : '';

        return $this->request('GET', self::BASE . '/zones' . $queryString);
    }

    /**
     * @param array<string, mixed> $query
     * @return array<int, array<string, mixed>>
     */
    public function listRecords(?string $zoneId = null, array $query = []): array
    {
        $zoneId ??= $this->config->zoneId();
        $records = [];
        $page = 1;

        do {
            $pageQuery = array_merge($query, ['page' => $page, 'per_page' => 100]);
            $queryString = '?' . http_build_query($pageQuery);
            $response = $this->request('GET', $this->zonePath('/dns_records' . $queryString, $zoneId));
            $results = $response['result'] ?? [];

            if (is_array($results)) {
                foreach ($results as $record) {
                    if (is_array($record)) {
                        $records[] = $record;
                    }
                }
            }

            $resultInfo = $response['result_info'] ?? [];
            $totalPages = is_array($resultInfo) ? (int) ($resultInfo['total_pages'] ?? 1) : 1;
            ++$page;
        } while ($page <= $totalPages);

        return $records;
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    public function createRecord(array $payload, ?string $zoneId = null): array
    {
        return $this->request('POST', $this->zonePath('/dns_records', $zoneId), ['json' => $payload]);
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    public function updateRecord(string $recordId, array $payload, ?string $zoneId = null): array
    {
        return $this->request('PATCH', $this->zonePath('/dns_records/' . $recordId, $zoneId), ['json' => $payload]);
    }

    /**
     * @return array<string, mixed>
     */
    public function deleteRecord(string $recordId, ?string $zoneId = null): array
    {
        return $this->request('DELETE', $this->zonePath('/dns_records/' . $recordId, $zoneId));
    }

    /**
     * @return array<string, mixed>
     */
    public function getRecord(string $recordId, ?string $zoneId = null): array
    {
        return $this->request('GET', $this->zonePath('/dns_records/' . $recordId, $zoneId));
    }

    /**
     * @return array<string, mixed>
     */
    private function request(string $method, string $url, array $options = []): array
    {
        $options['headers'] = array_merge($options['headers'] ?? [], [
            'Authorization' => 'Bearer ' . $this->config->cloudflareApiToken(),
            'Content-Type' => 'application/json',
            'Accept' => 'application/json',
        ]);

        $response = $this->context->http()->request($method, $url, $options);
        $decoded = json_decode($response['body'], true);

        if (!is_array($decoded)) {
            throw new PluginException('Cloudflare returned an invalid JSON response.');
        }

        if ($response['status'] >= 400 || !($decoded['success'] ?? false)) {
            $errors = $decoded['errors'] ?? [];
            $message = is_array($errors) && isset($errors[0]['message'])
                ? (string) $errors[0]['message']
                : 'Cloudflare API request failed.';

            throw new PluginException($message);
        }

        return $decoded;
    }

    private function zonePath(string $suffix, ?string $zoneId = null): string
    {
        $zoneId ??= $this->config->zoneId();

        return self::BASE . '/zones/' . $zoneId . $suffix;
    }
}
