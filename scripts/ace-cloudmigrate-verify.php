<?php
require '/var/www/html/lib/base.php';
\OC::$CLI = true;
$conn = \OCP\Server::get(\OCP\IDBConnection::class);
$cols = $conn->executeQuery("SHOW COLUMNS FROM oc_cm_migrations LIKE 'status_text'")->fetchAll();
echo count($cols) ? "status_text column OK\n" : "status_text MISSING\n";
$app = \OCP\Server::get(\OC\App\IAppManager::class);
$ver = $app->getAppVersion('cloudmigrate');
echo "App version: $ver\n";
