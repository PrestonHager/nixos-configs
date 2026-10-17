<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Settings;

use OCA\CloudMigrate\AppInfo\Application;
use OCA\CloudMigrate\Service\GraphClient;
use OCA\CloudMigrate\Service\TokenStore;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\Settings\ISettings;
use OCP\Util;

class Admin implements ISettings {
	public function __construct(
		private TokenStore $tokenStore,
		private GraphClient $graphClient,
	) {
	}

	public function getForm(): TemplateResponse {
		Util::addScript(Application::APP_ID, 'settings-admin');
		return new TemplateResponse(Application::APP_ID, 'settings/admin', [
			'clientId' => $this->tokenStore->getAdminClientId(),
			'tenant' => $this->tokenStore->getAdminTenant(),
			'redirectUri' => $this->graphClient->getRedirectUri(),
			'redirectUriCandidates' => $this->graphClient->getRedirectUriCandidates(),
			'redirectUriBase' => $this->tokenStore->getAdminRedirectUriBase(),
			'rclonePath' => $this->tokenStore->getAdminRclonePath(),
			'hasSecret' => $this->tokenStore->getAdminClientSecret() !== '',
		], '');
	}

	public function getSection(): string {
		return 'cloudmigrate';
	}

	public function getPriority(): int {
		return 50;
	}
}
