<?php
declare(strict_types=1);
$_SERVER['REQUEST_METHOD'] = 'GET';
$_SERVER['HTTP_HOST'] = 'cloud.prestonhager.com';
$_SERVER['HTTPS'] = 'on';
$_SERVER['REQUEST_URI'] = '/apps/cloudmigrate/';
require_once '/var/www/html/lib/base.php';
\OC_App::loadApps(['cloudmigrate']);
$url = \OCP\Server::get(\OCP\IURLGenerator::class);
$router = \OCP\Server::get(\OCP\Route\IRouter::class);
echo 'CLI=' . (\OC::$CLI ? 'true' : 'false') . PHP_EOL;
echo 'WEBROOT=' . \OC::$WEBROOT . PHP_EOL;
echo 'router generate: ' . $router->generate('cloudmigrate.oauth.onedrive') . PHP_EOL;
echo 'linkToRoute: ' . $url->linkToRoute('cloudmigrate.oauth.onedrive') . PHP_EOL;
echo 'linkToRouteAbsolute: ' . $url->linkToRouteAbsolute('cloudmigrate.oauth.onedrive') . PHP_EOL;
