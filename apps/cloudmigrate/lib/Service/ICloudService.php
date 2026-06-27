<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

class ICloudService {
	public function __construct(
		private TokenStore $tokenStore,
		private RcloneRunner $rcloneRunner,
	) {
	}

	public function isConnected(string $userId): bool {
		return $this->tokenStore->isIcloudConfigured($userId);
	}

	public function isRcloneAvailable(): bool {
		return $this->rcloneRunner->isAvailable();
	}

	/**
	 * @return list<array{id: string, name: string, path: string, folder: bool, size: int}>
	 */
	public function listFolders(string $userId, string $parentPath = ''): array {
		if (!$this->isConnected($userId)) {
			throw new \RuntimeException('Connect iCloud before listing folders');
		}
		if (!$this->isRcloneAvailable()) {
			throw new \RuntimeException('rclone is not available on the server. Ask an administrator to install rclone for the Nextcloud container.');
		}
		return $this->rcloneRunner->listFolders($userId, $parentPath);
	}
}
