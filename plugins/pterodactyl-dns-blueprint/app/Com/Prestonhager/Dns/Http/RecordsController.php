<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Http;

use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpRequest;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginHttpResponse;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginException;

class RecordsController
{
    public function index(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        Services::dnsPolicy($context)->ensureAdminDnsAccess($request);

        $serverId = $this->requireServerId($request);
        $records = Services::dns($context)->listRecordsForServer($serverId);

        return PluginHttpResponse::json([
            'object' => 'list',
            'data' => $records,
        ]);
    }

    public function store(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        Services::dnsPolicy($context)->ensureAdminDnsAccess($request);

        $serverId = $this->requireServerId($request);
        $server = $context->servers()->find($serverId);
        $record = Services::dns($context)->createRecord($serverId, $server, $request->body);

        return PluginHttpResponse::json([
            'object' => 'dns_record',
            'attributes' => $record,
        ], 201);
    }

    public function update(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        Services::dnsPolicy($context)->ensureAdminDnsAccess($request);

        $serverId = $this->requireServerId($request);
        $recordId = (string) $request->route('recordId', '');
        $server = $context->servers()->find($serverId);
        $record = Services::dns($context)->updateRecord($serverId, $server, $recordId, $request->body);

        return PluginHttpResponse::json([
            'object' => 'dns_record',
            'attributes' => $record,
        ]);
    }

    public function destroy(PluginContext $context, PluginHttpRequest $request): PluginHttpResponse
    {
        Services::dnsPolicy($context)->ensureAdminDnsAccess($request);

        $serverId = $this->requireServerId($request);
        $recordId = (string) $request->route('recordId', '');
        if ($recordId === '' && isset($request->body['record_id'])) {
            $recordId = (string) $request->body['record_id'];
        }

        Services::dns($context)->deleteRecord(
            $serverId,
            $recordId,
            $this->optionalString($request->query['name'] ?? $request->body['name'] ?? null),
            $this->optionalString($request->query['type'] ?? $request->body['type'] ?? null),
        );

        return PluginHttpResponse::json([], 204);
    }

    private function requireServerId(PluginHttpRequest $request): int
    {
        if (is_null($request->serverId)) {
            throw new PluginException('Server context is required.');
        }

        return $request->serverId;
    }

    private function optionalString(mixed $value): ?string
    {
        if (!is_string($value)) {
            return null;
        }

        $value = trim($value);

        return $value !== '' ? $value : null;
    }
}
