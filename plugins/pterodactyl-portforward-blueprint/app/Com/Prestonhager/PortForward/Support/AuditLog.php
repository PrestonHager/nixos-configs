<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

class AuditLog
{
    /**
     * @param string[] $commands
     */
    public function log(
        string $action,
        array $commands,
        bool $success,
        ?string $stdout = null,
        ?string $error = null,
        ?int $serverId = null,
        ?int $userId = null,
    ): void {
        if (!Schema::hasTable('portforward_audit_log')) {
            return;
        }

        DB::table('portforward_audit_log')->insert([
            'user_id' => $userId,
            'server_id' => $serverId,
            'action' => $action,
            'ios_commands' => implode("\n", $commands),
            'stdout' => $stdout !== null ? mb_substr($stdout, 0, 8000) : null,
            'success' => $success,
            'error_message' => $error,
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function recent(int $limit = 50, ?int $serverId = null): array
    {
        if (!Schema::hasTable('portforward_audit_log')) {
            return [];
        }

        $query = DB::table('portforward_audit_log')->orderByDesc('id')->limit($limit);
        if (!is_null($serverId)) {
            $query->where('server_id', $serverId);
        }

        return array_map(static fn ($row) => (array) $row, $query->get()->all());
    }
}
