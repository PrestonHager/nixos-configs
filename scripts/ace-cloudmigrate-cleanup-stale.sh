#!/usr/bin/env bash
# Mark stale running Cloud Migrate jobs failed via Nextcloud bootstrap.
set -euo pipefail
podman exec -u www-data nextcloud php <<'PHP'
<?php
require '/var/www/html/lib/base.php';
\OC::$CLI = true;
$conn = \OCP\Server::get(\OCP\IDBConnection::class);
$updated = $conn->executeStatement(
    "UPDATE oc_cm_migrations SET status = 'failed', phase = '', status_text = '', worker_pid = NULL,
     error_message = 'Interrupted by server restart or worker crash', updated_at = ?
     WHERE status IN ('running', 'queued')",
    [time()]
);
echo "Updated rows: $updated\n";
$rows = $conn->executeQuery(
    'SELECT id, provider, status, error_message FROM oc_cm_migrations ORDER BY id DESC LIMIT 5'
)->fetchAll();
foreach ($rows as $row) {
    echo $row['id'] . "\t" . $row['provider'] . "\t" . $row['status'] . "\t" . ($row['error_message'] ?? '') . "\n";
}
PHP
