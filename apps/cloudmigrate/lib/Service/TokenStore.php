<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCA\CloudMigrate\AppInfo\Application;
use OCP\IConfig;
use OCP\Security\ICrypto;

/**
 * Encrypts and stores per-user OAuth tokens and iCloud credentials in app config.
 */
class TokenStore {
	public const KEY_ONEDRIVE = 'onedrive_token';
	public const KEY_ICLOUD_APPLE_ID = 'icloud_apple_id';
	public const KEY_ICLOUD_PASSWORD = 'icloud_app_password';
	public const KEY_ICLOUD_SESSION = 'icloud_rclone_session';

	public function __construct(
		private IConfig $config,
		private ICrypto $crypto,
	) {
	}

	public function storeOneDriveToken(string $userId, array $tokenData): void {
		$payload = json_encode($tokenData, JSON_THROW_ON_ERROR);
		$this->config->setUserValue($userId, Application::APP_ID, self::KEY_ONEDRIVE, $this->crypto->encrypt($payload));
	}

	public function getOneDriveToken(string $userId): ?array {
		$encrypted = $this->config->getUserValue($userId, Application::APP_ID, self::KEY_ONEDRIVE, '');
		if ($encrypted === '') {
			return null;
		}
		try {
			$json = $this->crypto->decrypt($encrypted);
			return json_decode($json, true, 512, JSON_THROW_ON_ERROR);
		} catch (\Throwable) {
			return null;
		}
	}

	public function clearOneDriveToken(string $userId): void {
		$this->config->deleteUserValue($userId, Application::APP_ID, self::KEY_ONEDRIVE);
	}

	public function storeIcloudCredentials(string $userId, string $appleId, string $password): void {
		$this->config->setUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_APPLE_ID, $appleId);
		$this->config->setUserValue(
			$userId,
			Application::APP_ID,
			self::KEY_ICLOUD_PASSWORD,
			$this->crypto->encrypt($password),
		);
		$this->clearIcloudSession($userId);
	}

	public function getIcloudAppleId(string $userId): ?string {
		$value = $this->config->getUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_APPLE_ID, '');
		return $value !== '' ? $value : null;
	}

	public function getIcloudPassword(string $userId): ?string {
		return $this->getIcloudAppPassword($userId);
	}

	public function getIcloudAppPassword(string $userId): ?string {
		$encrypted = $this->config->getUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_PASSWORD, '');
		if ($encrypted === '') {
			return null;
		}
		try {
			return $this->crypto->decrypt($encrypted);
		} catch (\Throwable) {
			return null;
		}
	}

	public function clearIcloudCredentials(string $userId): void {
		$this->config->deleteUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_APPLE_ID);
		$this->config->deleteUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_PASSWORD);
		$this->clearIcloudSession($userId);
	}

	/**
	 * @param array{trust_token: string, cookies?: string, authenticated_at?: int} $session
	 */
	public function storeIcloudSession(string $userId, array $session): void {
		$payload = json_encode($session, JSON_THROW_ON_ERROR);
		$this->config->setUserValue(
			$userId,
			Application::APP_ID,
			self::KEY_ICLOUD_SESSION,
			$this->crypto->encrypt($payload),
		);
	}

	/**
	 * @return array{trust_token: string, cookies?: string, authenticated_at?: int}|null
	 */
	public function getIcloudSession(string $userId): ?array {
		$encrypted = $this->config->getUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_SESSION, '');
		if ($encrypted === '') {
			return null;
		}
		try {
			$json = $this->crypto->decrypt($encrypted);
			/** @var array{trust_token: string, cookies?: string, authenticated_at?: int} $session */
			$session = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
			return $session;
		} catch (\Throwable) {
			return null;
		}
	}

	public function hasIcloudSession(string $userId): bool {
		$session = $this->getIcloudSession($userId);
		return $session !== null && ($session['trust_token'] ?? '') !== '';
	}

	public function clearIcloudSession(string $userId): void {
		$this->config->deleteUserValue($userId, Application::APP_ID, self::KEY_ICLOUD_SESSION);
	}

	public function getAdminClientId(): string {
		return $this->config->getAppValue(Application::APP_ID, 'onedrive_client_id', '');
	}

	public function getAdminClientSecret(): string {
		return $this->config->getAppValue(Application::APP_ID, 'onedrive_client_secret', '');
	}

	public function getAdminTenant(): string {
		return $this->config->getAppValue(Application::APP_ID, 'onedrive_tenant', 'common');
	}

	/** Optional override for OAuth redirect base (scheme + host, no trailing slash). */
	public function getAdminRedirectUriBase(): string {
		return $this->config->getAppValue(Application::APP_ID, 'onedrive_redirect_uri_base', '');
	}

	public function getAdminRclonePath(): string {
		return $this->config->getAppValue(Application::APP_ID, 'rclone_path', '');
	}

	public function setAdminSettings(
		string $clientId,
		string $clientSecret,
		string $tenant,
		string $redirectUriBase = '',
		string $rclonePath = '',
	): void {
		$this->config->setAppValue(Application::APP_ID, 'onedrive_client_id', $clientId);
		if ($clientSecret !== '') {
			$this->config->setAppValue(Application::APP_ID, 'onedrive_client_secret', $clientSecret);
		}
		$this->config->setAppValue(Application::APP_ID, 'onedrive_tenant', $tenant !== '' ? $tenant : 'common');
		$this->config->setAppValue(Application::APP_ID, 'onedrive_redirect_uri_base', trim($redirectUriBase));
		$this->config->setAppValue(Application::APP_ID, 'rclone_path', trim($rclonePath));
	}

	public function isOneDriveConnected(string $userId): bool {
		return $this->getOneDriveToken($userId) !== null;
	}

	public function isIcloudConfigured(string $userId): bool {
		return $this->getIcloudAppleId($userId) !== null && $this->getIcloudPassword($userId) !== null;
	}
}
