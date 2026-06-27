<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Technitium;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class Client
{
    public function __construct(
        private readonly PluginContext $context,
        private readonly Config $config,
    ) {
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function listZones(): array
    {
        $response = $this->request('GET', '/api/zones/list');
        $zones = $response['response']['zones'] ?? [];

        return is_array($zones) ? $zones : [];
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    public function addRecord(array $payload, string $zone): array
    {
        $query = $this->recordQueryParams($payload, $zone);
        $query['overwrite'] = 'true';

        return $this->request('POST', '/api/zones/records/add?' . http_build_query($query));
    }

    /**
     * @param array<string, mixed> $payload
     */
    public function deleteRecord(array $payload, string $zone): void
    {
        $query = $this->recordQueryParams($payload, $zone);
        $this->request('POST', '/api/zones/records/delete?' . http_build_query($query));
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, string>
     */
    private function recordQueryParams(array $payload, string $zone): array
    {
        $type = strtoupper((string) ($payload['type'] ?? ''));
        $domain = rtrim((string) ($payload['name'] ?? $payload['domain'] ?? ''), '.');
        $ttl = (string) ($payload['ttl'] ?? $this->config->defaultTtl());

        $params = [
            'token' => $this->config->technitiumApiToken(),
            'zone' => $zone,
            'domain' => $domain,
            'type' => $type,
            'ttl' => $ttl !== '1' ? $ttl : '3600',
        ];

        return match ($type) {
            'A' => array_merge($params, [
                'ipAddress' => (string) ($payload['content'] ?? $payload['ipAddress'] ?? ''),
            ]),
            'AAAA' => array_merge($params, [
                'ipAddress' => (string) ($payload['content'] ?? $payload['ipAddress'] ?? ''),
            ]),
            'CNAME' => array_merge($params, [
                'cname' => rtrim((string) ($payload['content'] ?? $payload['cname'] ?? ''), '.'),
            ]),
            'TXT' => array_merge($params, [
                'text' => (string) ($payload['content'] ?? $payload['text'] ?? ''),
            ]),
            'SRV' => $this->srvParams($params, $payload),
            default => throw new PluginException(sprintf('Technitium does not support record type "%s".', $type)),
        };
    }

    /**
     * @param array<string, string> $params
     * @param array<string, mixed> $payload
     * @return array<string, string>
     */
    private function srvParams(array $params, array $payload): array
    {
        $data = is_array($payload['data'] ?? null) ? $payload['data'] : $payload;

        return array_merge($params, [
            'priority' => (string) ($data['priority'] ?? 0),
            'weight' => (string) ($data['weight'] ?? 5),
            'port' => (string) ($data['port'] ?? 0),
            'target' => rtrim((string) ($data['target'] ?? ''), '.'),
        ]);
    }

    /**
     * @return array<string, mixed>
     */
    private function request(string $method, string $path): array
    {
        $url = rtrim($this->config->technitiumApiUrl(), '/') . $path;
        $response = $this->context->http()->request($method, $url);
        $decoded = json_decode($response['body'], true);

        if (!is_array($decoded)) {
            throw new PluginException('Technitium returned an invalid JSON response.');
        }

        if ($response['status'] >= 400 || ($decoded['status'] ?? '') === 'error') {
            $message = (string) ($decoded['errorMessage'] ?? $decoded['response'] ?? 'Technitium API request failed.');

            throw new PluginException($message);
        }

        return $decoded;
    }

    public static function recordKey(string $zone, string $domain, string $type): string
    {
        return sprintf('technitium:%s:%s:%s', $zone, rtrim($domain, '.'), strtoupper($type));
    }
}
