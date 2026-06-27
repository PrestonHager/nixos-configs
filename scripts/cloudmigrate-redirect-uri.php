<?php
declare(strict_types=1);
require_once '/var/www/html/lib/base.php';
$config = \OCP\Server::get(\OCP\IConfig::class);
$primary = rtrim($config->getSystemValueString('overwrite.cli.url'), '/') . '/apps/cloudmigrate/oauth/onedrive';
$alternate = preg_replace('#^(https?://[^/]+)/apps/#', '$1/index.php/apps/', $primary);
echo 'redirect_uri=' . $primary . PHP_EOL;
echo 'candidate_1=' . $alternate . PHP_EOL;
