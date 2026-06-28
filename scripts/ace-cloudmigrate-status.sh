#!/usr/bin/env bash
# Query Cloud Migrate jobs via Nextcloud bootstrap (run on ace as root).
set -euo pipefail
podman exec -u www-data nextcloud php <<'PHP'
<?php
require '/var/www/html/lib/base.php';
\OC::$CLI = true;
$conn = \OCP\Server::get(\OCP\IDBConnection::class);
$rows = $conn->executeQuery(
    'SELECT id, provider, status, progress, total_files, copied_files, worker_pid, error_message FROM oc_cm_migrations ORDER BY id DESC LIMIT 10'
)->fetchAll();
foreach ($rows as $row) {
    echo implode("\t", array_map(static fn ($v) => (string)($v ?? ''), $row)) . "\n";
}
PHP
