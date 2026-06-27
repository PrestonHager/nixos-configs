<?php

declare(strict_types=1);

return [
	'routes' => [
		['name' => 'page#index', 'url' => '/', 'verb' => 'GET'],
		['name' => 'oauth#onedrive', 'url' => '/oauth/onedrive', 'verb' => 'GET'],
		['name' => 'api#status', 'url' => '/api/status', 'verb' => 'GET'],
		['name' => 'api#onedriveFolders', 'url' => '/api/onedrive/folders', 'verb' => 'GET'],
		['name' => 'api#onedriveBrowse', 'url' => '/api/onedrive/browse', 'verb' => 'GET'],
		['name' => 'api#onedriveResolvePath', 'url' => '/api/onedrive/resolve-path', 'verb' => 'GET'],
		['name' => 'api#icloudAuthStart', 'url' => '/api/icloud/auth/start', 'verb' => 'POST'],
		['name' => 'api#icloudAuthContinue', 'url' => '/api/icloud/auth/continue', 'verb' => 'POST'],
		['name' => 'api#icloudFolders', 'url' => '/api/icloud/folders', 'verb' => 'GET'],
		['name' => 'api#startMigration', 'url' => '/api/migrate', 'verb' => 'POST'],
		['name' => 'api#disconnect', 'url' => '/api/disconnect/{provider}', 'verb' => 'POST'],
		['name' => 'api#saveIcloud', 'url' => '/api/icloud/credentials', 'verb' => 'POST'],
		['name' => 'settings#storeAdmin', 'url' => '/settings/admin', 'verb' => 'POST'],
	],
];
