<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Controller;

use OCA\CloudMigrate\AppInfo\Application;
use OCA\CloudMigrate\Db\MigrationEntity;
use OCA\CloudMigrate\Service\MigrationService;
use OCA\CloudMigrate\Service\OneDriveService;
use OCA\CloudMigrate\Service\TokenStore;
use OCP\AppFramework\ApiController;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\DataResponse;
use OCP\IRequest;
use OCP\IUserSession;

class ApiController extends ApiController {
	public function __construct(
		string $appName,
		IRequest $request,
		private IUserSession $userSession,
		private TokenStore $tokenStore,
		private OneDriveService $oneDriveService,
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
				'configured' => $this->tokenStore->isIcloudConfigured($userId),
				'phase' => 'scaffold',
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
	public function startMigration(): DataResponse {
		$userId = $this->requireUserId();
		$body = $this->request->getParams();
		$provider = (string)($body['provider'] ?? '');
		$folderId = (string)($body['folderId'] ?? '');
		$sourceLabel = (string)($body['sourceLabel'] ?? '/');
		$destSubpath = (string)($body['destSubpath'] ?? 'Files');
		$dryRun = filter_var($body['dryRun'] ?? false, FILTER_VALIDATE_BOOLEAN);

		if ($provider !== 'onedrive') {
			return new DataResponse(['message' => 'Only OneDrive migrations are available in Phase 1'], 400);
		}
		if ($folderId === '') {
			return new DataResponse(['message' => 'folderId is required'], 400);
		}
		try {
			$migration = $this->migrationService->startOneDriveMigration(
				$userId,
				$folderId,
				$sourceLabel,
				$dryRun,
				$destSubpath,
			);
			return new DataResponse(['migration' => $this->serializeMigration($migration)]);
		} catch (\Throwable $e) {
			return new DataResponse(['message' => $e->getMessage()], 500);
		}
	}

	#[NoAdminRequired]
	public function disconnect(string $provider): DataResponse {
		$userId = $this->requireUserId();
		if ($provider === 'onedrive') {
			$this->tokenStore->clearOneDriveToken($userId);
		} elseif ($provider === 'icloud') {
			$this->tokenStore->clearIcloudCredentials($userId);
		} else {
			return new DataResponse(['message' => 'Unknown provider'], 400);
		}
		return new DataResponse(['ok' => true]);
	}

	#[NoAdminRequired]
	public function saveIcloud(): DataResponse {
		$userId = $this->requireUserId();
		$body = $this->request->getParams();
		$appleId = trim((string)($body['appleId'] ?? ''));
		$appPassword = trim((string)($body['appPassword'] ?? ''));
		if ($appleId === '' || $appPassword === '') {
			return new DataResponse(['message' => 'Apple ID and app-specific password are required'], 400);
		}
		$this->tokenStore->storeIcloudCredentials($userId, $appleId, $appPassword);
		return new DataResponse([
			'ok' => true,
			'message' => 'iCloud credentials saved (encrypted). Drive/Photos migration jobs are not yet implemented.',
		]);
	}

	private function requireUserId(): string {
		$user = $this->userSession->getUser();
		if ($user === null) {
			throw new \RuntimeException('Not logged in');
		}
		return $user->getUID();
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
