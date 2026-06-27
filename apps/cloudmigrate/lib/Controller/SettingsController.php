<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Controller;

use OCA\CloudMigrate\Service\TokenStore;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\AdminRequired;
use OCP\AppFramework\Http\DataResponse;
use OCP\IRequest;

class SettingsController extends Controller {
	public function __construct(
		string $appName,
		IRequest $request,
		private TokenStore $tokenStore,
	) {
		parent::__construct($appName, $request);
	}

	#[AdminRequired]
	public function storeAdmin(): DataResponse {
		$params = $this->request->getParams();
		$clientId = trim((string)($params['onedrive_client_id'] ?? ''));
		$clientSecret = trim((string)($params['onedrive_client_secret'] ?? ''));
		$tenant = trim((string)($params['onedrive_tenant'] ?? 'common'));
		$this->tokenStore->setAdminSettings($clientId, $clientSecret, $tenant);
		return new DataResponse(['ok' => true]);
	}
}
