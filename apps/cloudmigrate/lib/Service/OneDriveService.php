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

	/**
	 * @return array{
	 *   folderId: string,
	 *   folderPath: string,
	 *   breadcrumb: list<array{id: string, name: string}>,
	 *   folders: list<array{id: string, name: string, path: string, folder: bool, size: int}>,
	 *   fileCount: int
	 * }
	 */
	public function browse(string $userId, ?string $folderId = null): array {
		if ($folderId === null || $folderId === '' || $folderId === 'root') {
			$folderId = 'root';
			$folderPath = '';
			$breadcrumb = [['id' => 'root', 'name' => 'OneDrive', 'path' => '']];
			$children = $this->graphClient->listChildren($userId);
		} elseif ($this->looksLikeDrivePath($folderId)) {
			$item = $this->graphClient->resolvePath($userId, $folderId);
			if (!$item['folder']) {
				throw new \RuntimeException('Selected item is not a folder');
			}
			$folderId = $item['id'];
			$folderPath = $item['path'];
			$breadcrumb = $this->buildBreadcrumb($folderPath);
			$children = $this->graphClient->listChildren($userId, $folderId);
		} else {
			$item = $this->graphClient->getDriveItem($userId, $folderId);
			if (!isset($item['folder'])) {
				throw new \RuntimeException('Selected item is not a folder');
			}
			$folderPath = $this->graphClient->itemDisplayPath($item);
			$breadcrumb = $this->buildBreadcrumb($folderPath);
			$children = $this->graphClient->listChildren($userId, $folderId);
		}

		$folders = array_values(array_filter($children, static fn (array $item): bool => $item['folder']));
		$fileCount = count(array_filter($children, static fn (array $item): bool => !$item['folder']));

		return [
			'folderId' => $folderId,
			'folderPath' => $folderPath,
			'breadcrumb' => $breadcrumb,
			'folders' => $folders,
			'fileCount' => $fileCount,
		];
	}

	public function resolveFolder(string $userId, string $path): array {
		$item = $this->graphClient->resolvePath($userId, $path);
		if (!$item['folder']) {
			throw new \RuntimeException('Path must be a folder, not a file');
		}
		return $item;
	}

	public function displayPathForItem(string $userId, string $folderId): string {
		if ($folderId === '' || $folderId === 'root') {
			return 'OneDrive';
		}
		$item = $this->graphClient->getDriveItem($userId, $folderId);
		return $this->graphClient->itemDisplayPath($item);
	}

	/**
	 * @return list<array{id: string, name: string, path: string}>
	 */
	private function buildBreadcrumb(string $folderPath): array {
		$crumb = [['id' => 'root', 'name' => 'OneDrive', 'path' => '']];
		if ($folderPath === '') {
			return $crumb;
		}
		$accum = '';
		foreach (explode('/', $folderPath) as $segment) {
			$accum = $accum === '' ? $segment : $accum . '/' . $segment;
			$crumb[] = ['id' => $accum, 'name' => $segment, 'path' => $accum];
		}
		return $crumb;
	}

	private function looksLikeDrivePath(string $folderId): bool {
		if (str_contains($folderId, '/')) {
			return true;
		}
		return $folderId !== 'root' && !str_contains($folderId, '!') && strlen($folderId) < 64;
	}
}
