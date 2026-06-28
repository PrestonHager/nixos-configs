<?php
require '/var/www/html/lib/base.php';
\OC::$CLI = true;
$conn = \OCP\Server::get(\OCP\IDBConnection::class);
$rows = $conn->executeQuery(
    'SELECT id, provider, status, progress, total_files, copied_files, worker_pid, error_message FROM oc_cm_migrations ORDER BY id DESC LIMIT 10'
)->fetchAll();
foreach ($rows as $row) {
    echo $row['id'] . "\t" . $row['provider'] . "\t" . $row['status'] . "\t" .
        $row['progress'] . "\t" . $row['total_files'] . "/" . $row['copied_files'] . "\t" .
        ($row['error_message'] ?? '') . "\n";
}
