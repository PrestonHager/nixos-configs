<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

class ICloudService {
	public function __construct(
		private TokenStore $tokenStore,
		private RcloneRunner $rcloneRunner,
		private RcloneAuthService $rcloneAuthService,
	) {
	}

	public function isConnected(string $userId): bool {
		return $this->tokenStore->isIcloudConfigured($userId);
	}

	public function isAuthenticated(string $userId): bool {
		return $this->tokenStore->hasIcloudSession($userId);
	}

	public function getAuthStatus(string $userId): string {
		return $this->rcloneAuthService->getAuthStatus($userId);
	}

	public function getAuthPendingState(string $userId): ?string {
		return $this->rcloneAuthService->getPendingAuthState($userId);
	}

	public function isRcloneAvailable(): bool {
		return $this->rcloneRunner->isAvailable();
	}

	/**
	 * @return array{status: string, state?: string, message: string, option?: array<string, mixed>}
	 */
	public function startAuth(string $userId, bool $restart = false): array {
		return $this->rcloneAuthService->startAuth($userId, $restart);
	}

	/**
	 * @return array{status: string, state?: string, message: string, option?: array<string, mixed>}
	 */
	public function continueAuth(string $userId, string $state, string $code): array {
		return $this->rcloneAuthService->continueAuth($userId, $state, $code);
	}

	public function disconnect(string $userId): void {
		$this->rcloneAuthService->clearAuthState($userId);
		$this->tokenStore->clearIcloudCredentials($userId);
	}

	/**
	 * @return list<array{id: string, name: string, path: string, folder: bool, size: int}>
	 */
	public function listFolders(string $userId, string $parentPath = ''): array {
		if (!$this->isConnected($userId)) {
			throw new \RuntimeException('Connect iCloud before listing folders');
		}
		if (!$this->isAuthenticated($userId)) {
			throw new \RuntimeException('Complete iCloud sign-in (2FA) before listing folders');
		}
		if (!$this->isRcloneAvailable()) {
			throw new \RuntimeException('rclone is not available on the server. Ask an administrator to install rclone for the Nextcloud container.');
		}
		return $this->rcloneRunner->listFolders($userId, $parentPath);
	}
}
