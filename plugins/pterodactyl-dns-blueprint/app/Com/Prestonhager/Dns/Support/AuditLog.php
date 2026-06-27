<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

class AuditLog
{
    /**
     * @param array<string, mixed> $details
     */
    public function log(string $action, string $provider, string $recordName, array $details = [], ?int $serverId = null, ?int $userId = null): void
    {
        if (!Schema::hasTable('dnsrecords_audit_log')) {
            return;
        }

        DB::table('dnsrecords_audit_log')->insert([
            'user_id' => $userId,
            'server_id' => $serverId,
            'action' => $action,
            'provider' => $provider,
            'record_name' => $recordName,
            'details' => json_encode($this->redact($details)),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function recent(int $limit = 50, ?int $serverId = null): array
    {
        if (!Schema::hasTable('dnsrecords_audit_log')) {
            return [];
        }

        $query = DB::table('dnsrecords_audit_log')->orderByDesc('id')->limit($limit);
        if (!is_null($serverId)) {
            $query->where('server_id', $serverId);
        }

        return array_map(static function ($row) {
            return [
                'id' => $row->id,
                'action' => $row->action,
                'provider' => $row->provider,
                'record_name' => $row->record_name,
                'details' => json_decode($row->details ?? '{}', true),
                'created_at' => $row->created_at,
            ];
        }, $query->get()->all());
    }

    /**
     * @param array<string, mixed> $details
     * @return array<string, mixed>
     */
    private function redact(array $details): array
    {
        $json = json_encode($details);
        if (!is_string($json)) {
            return $details;
        }

        $json = preg_replace('/("(?:token|password|secret|api_key)"\s*:\s*")[^"]*(")/i', '$1[REDACTED]$2', $json) ?? $json;

        return json_decode($json, true) ?? $details;
    }
}
