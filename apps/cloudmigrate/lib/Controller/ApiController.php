<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Controller;

use OCA\CloudMigrate\Db\MigrationEntity;
use OCA\CloudMigrate\Service\ICloudService;
use OCA\CloudMigrate\Service\MigrationService;
use OCA\CloudMigrate\Service\OneDriveService;
use OCA\CloudMigrate\Service\PathValidator;
use OCA\CloudMigrate\Service\TokenStore;
use OCP\AppFramework\ApiController as BaseApiController;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\DataResponse;
use OCP\IRequest;
use OCP\IUserSession;

class ApiController extends BaseApiController {
	public function __construct(
		string $appName,
		IRequest $request,
		private IUserSession $userSession,
		private TokenStore $tokenStore,
		private OneDriveService $oneDriveService,
		private ICloudService $iCloudService,
		private MigrationService $migrationService,
	) {
		parent::__construct($appName, $request);
	}

	#[NoAdminRequired]
	public function status(): DataResponse {
		$userId = $this->requireUserId();
		$migrations = array_map([$this, 'serializeMigration'], $this->migrationService->listForUser($userId));
		return new DataResponse([
			'onedrive' => [
				'adminConfigured' => $this->oneDriveService->isConfigured(),
				'connected' => $this->oneDriveService->isConnected($userId),
			],
			'icloud' => [
				'oauthAvailable' => false,
				'configured' => $this->iCloudService->isConnected($userId),
				'authenticated' => $this->iCloudService->isAuthenticated($userId),
				'authStatus' => $this->iCloudService->getAuthStatus($userId),
				'authState' => $this->iCloudService->getAuthPendingState($userId) ?? '',
				'rcloneAvailable' => $this->iCloudService->isRcloneAvailable(),
				'phase' => 'beta',
			],
			'migrations' => $migrations,
		]);
	}

	#[NoAdminRequired]
	public function onedriveFolders(): DataResponse {
		$userId = $this->requireUserId();
		if (!$this->oneDriveService->isConnected($userId)) {
			return new DataResponse(['message' => 'OneDrive not connected'], 400);
		}
		try {
			return new DataResponse(['folders' => $this->oneDriveService->listRootFolders($userId)]);
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function onedriveBrowse(): DataResponse {
		$userId = $this->requireUserId();
		if (!$this->oneDriveService->isConnected($userId)) {
			return new DataResponse(['message' => 'OneDrive not connected'], 400);
		}
		$folderId = (string)($this->request->getParam('folderId') ?? 'root');
		try {
			return new DataResponse($this->oneDriveService->browse($userId, $folderId === '' ? 'root' : $folderId));
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function onedriveResolvePath(): DataResponse {
		$userId = $this->requireUserId();
		if (!$this->oneDriveService->isConnected($userId)) {
			return new DataResponse(['message' => 'OneDrive not connected'], 400);
		}
		$path = (string)($this->request->getParam('path') ?? '');
		try {
			$item = $this->oneDriveService->resolveFolder($userId, $path);
			return new DataResponse([
				'folderId' => $item['id'],
				'folderPath' => $item['path'] !== '' ? $item['path'] : 'OneDrive',
				'name' => $item['name'],
			]);
		} catch (\InvalidArgumentException $e) {
			return new DataResponse(['message' => $e->getMessage()], 400);
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function icloudAuthStart(): DataResponse {
		$userId = $this->requireUserId();
		$body = $this->getRequestBody();
		$restart = filter_var($body['restart'] ?? false, FILTER_VALIDATE_BOOLEAN);
		try {
			return new DataResponse($this->iCloudService->startAuth($userId, $restart));
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function icloudAuthContinue(): DataResponse {
		$userId = $this->requireUserId();
		$body = $this->getRequestBody();
		$state = trim((string)($body['state'] ?? ''));
		$code = trim((string)($body['code'] ?? ''));
		if ($code === '') {
			return new DataResponse(['message' => '2FA code is required'], 400);
		}
		try {
			return new DataResponse($this->iCloudService->continueAuth($userId, $state, $code));
		} catch (\InvalidArgumentException $e) {
			return new DataResponse(['message' => $e->getMessage()], 400);
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function icloudFolders(): DataResponse {
		$userId = $this->requireUserId();
		if (!$this->iCloudService->isConnected($userId)) {
			return new DataResponse(['message' => 'iCloud not connected'], 400);
		}
		$parentPath = trim((string)($this->request->getParam('path', '')));
		try {
			return new DataResponse(['folders' => $this->iCloudService->listFolders($userId, $parentPath)]);
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function startMigration(): DataResponse {
		$userId = $this->requireUserId();
		$body = $this->getRequestBody();
		$provider = (string)($body['provider'] ?? '');
		$folderId = (string)($body['folderId'] ?? '');
		$sourceLabel = (string)($body['sourceLabel'] ?? '');
		$destBase = (string)($body['destBase'] ?? MigrationService::DEST_ONEDRIVE);
		$destSubpath = (string)($body['destSubpath'] ?? '');
		$dryRun = filter_var($body['dryRun'] ?? false, FILTER_VALIDATE_BOOLEAN);

		if ($provider === 'onedrive') {
			if ($folderId === '') {
				return new DataResponse(['message' => 'folderId is required'], 400);
			}
			try {
				PathValidator::normalizeDestPath($destBase, $destSubpath);
				$migration = $this->migrationService->startOneDriveMigration(
					$userId,
					$folderId,
					$sourceLabel,
					$dryRun,
					$destBase,
					$destSubpath,
				);
				return new DataResponse(['migration' => $this->serializeMigration($migration)]);
			} catch (\InvalidArgumentException $e) {
				return new DataResponse(['message' => $e->getMessage()], 400);
			} catch (\Throwable $e) {
				return new DataResponse(['message' => $e->getMessage()], 500);
			}
		}

		if ($provider === 'icloud') {
			$sourcePath = (string)($body['sourcePath'] ?? '');
			$destPath = trim((string)($body['destPath'] ?? MigrationService::DEST_ICLOUD));
			try {
				PathValidator::normalizeDestPath($destPath);
				if ($sourceLabel === '' || $sourceLabel === '/') {
					$sourceLabel = trim($sourcePath, '/') === ''
						? 'All iCloud Drive files'
						: trim($sourcePath, '/');
				}
				$migration = $this->migrationService->startIcloudMigration(
					$userId,
					$sourcePath,
					$sourceLabel,
					$dryRun,
					$destPath,
				);
				return new DataResponse(['migration' => $this->serializeMigration($migration)]);
			} catch (\InvalidArgumentException $e) {
				return new DataResponse(['message' => $e->getMessage()], 400);
			} catch (\Throwable $e) {
				return new DataResponse(['message' => $e->getMessage()], 500);
			}
		}

		return new DataResponse(['message' => 'Unknown provider: ' . $provider], 400);
	}

	#[NoAdminRequired]
	public function disconnect(string $provider): DataResponse {
		$userId = $this->requireUserId();
		if ($provider === 'onedrive') {
			$this->tokenStore->clearOneDriveToken($userId);
		} elseif ($provider === 'icloud') {
			$this->iCloudService->disconnect($userId);
		} else {
			return new DataResponse(['message' => 'Unknown provider'], 400);
		}
		return new DataResponse(['ok' => true]);
	}

	#[NoAdminRequired]
	public function saveIcloud(): DataResponse {
		$userId = $this->requireUserId();
		$body = $this->getRequestBody();
		$appleId = trim((string)($body['appleId'] ?? ''));
		$password = trim((string)($body['appPassword'] ?? $body['password'] ?? ''));
		if ($appleId === '' || $password === '') {
			return new DataResponse(['message' => 'Apple ID and Apple ID password are required'], 400);
		}
		$this->tokenStore->storeIcloudCredentials($userId, $appleId, $password);
		return new DataResponse([
			'ok' => true,
			'authStatus' => $this->iCloudService->getAuthStatus($userId),
			'message' => 'Credentials saved. Complete Apple two-factor sign-in next.',
		]);
	}

	private function requireUserId(): string {
		$user = $this->userSession->getUser();
		if ($user === null) {
			throw new \RuntimeException('Not logged in');
		}
		return $user->getUID();
	}

	/**
	 * Merge route/query params with JSON request body (fetch sends application/json).
	 *
	 * @return array<string, mixed>
	 */
	private function getRequestBody(): array {
		$params = $this->request->getParams();
		$contentType = $this->request->getHeader('Content-Type') ?? '';
		if (!str_contains(strtolower($contentType), 'application/json')) {
			return $params;
		}
		$raw = file_get_contents('php://input');
		if ($raw === false || trim($raw) === '') {
			return $params;
		}
		$decoded = json_decode($raw, true);
		if (!is_array($decoded)) {
			return $params;
		}
		return array_merge($params, $decoded);
	}

	private function serializeMigration(MigrationEntity $m): array {
		return [
			'id' => $m->getId(),
			'provider' => $m->getProvider(),
			'status' => $m->getStatus(),
			'sourcePath' => $m->getSourcePath(),
			'destPath' => $m->getDestPath(),
			'dryRun' => $m->isDryRun(),
			'progress' => $m->getProgress(),
			'totalFiles' => $m->getTotalFiles(),
			'copiedFiles' => $m->getCopiedFiles(),
			'errorMessage' => $m->getErrorMessage(),
			'createdAt' => $m->getCreatedAt(),
			'updatedAt' => $m->getUpdatedAt(),
		];
	}
}
