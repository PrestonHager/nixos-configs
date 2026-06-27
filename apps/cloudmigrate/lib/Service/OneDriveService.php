<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

class OneDriveService {
	public function __construct(
		private TokenStore $tokenStore,
		private GraphClient $graphClient,
	) {
	}

	public function isConfigured(): bool {
		return $this->tokenStore->getAdminClientId() !== '';
	}

	public function isConnected(string $userId): bool {
		return $this->tokenStore->isOneDriveConnected($userId);
	}

	/**
	 * @return list<array{id: string, name: string, path: string, folder: bool, size: int}>
	 */
	public function listRootFolders(string $userId): array {
		return array_values(array_filter(
			$this->graphClient->listChildren($userId),
			static fn (array $item): bool => $item['folder'],
		));
	}
}
