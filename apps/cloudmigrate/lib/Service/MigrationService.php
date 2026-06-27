<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCA\CloudMigrate\Db\MigrationEntity;
use OCA\CloudMigrate\Db\MigrationMapper;
use OCP\BackgroundJob\IJobList;
use OCP\Files\IRootFolder;
use OCP\Files\NotPermittedException;
use Psr\Log\LoggerInterface;

class MigrationService {
	public const DEST_ONEDRIVE = 'Migrated/OneDrive';
	public const DEST_ICLOUD_DRIVE = 'Migrated/iCloud/Drive';
	public const DEST_ICLOUD_PHOTOS = 'Migrated/iCloud/Photos';

	public function __construct(
		private MigrationMapper $mapper,
		private IJobList $jobList,
		private GraphClient $graphClient,
		private TokenStore $tokenStore,
		private IRootFolder $rootFolder,
		private LoggerInterface $logger,
	) {
	}

	public function startOneDriveMigration(
		string $userId,
		string $folderId,
		string $sourceLabel,
		bool $dryRun,
		string $destSubpath = 'Files',
	): MigrationEntity {
		if (!$this->tokenStore->isOneDriveConnected($userId)) {
			throw new \RuntimeException('Connect OneDrive before starting migration');
		}
		$entity = new MigrationEntity();
		$entity->setUserId($userId);
		$entity->setProvider('onedrive');
		$entity->setStatus('queued');
		$entity->setSourcePath($sourceLabel);
		$entity->setSourceItemId($folderId);
		$entity->setDestPath(self::DEST_ONEDRIVE . '/' . trim($destSubpath, '/'));
		$entity->setDryRun($dryRun);
		$entity->setProgress(0);
		$entity->setTotalFiles(0);
		$entity->setCopiedFiles(0);
		$entity->setCreatedAt(time());
		$entity->setUpdatedAt(time());
		$inserted = $this->mapper->insert($entity);
		$this->jobList->add(\OCA\CloudMigrate\BackgroundJob\MigrationJob::class, [
			'migrationId' => $inserted->getId(),
		]);
		return $inserted;
	}

	public function runMigration(int $migrationId): void {
		$entity = $this->mapper->findById($migrationId);
		if ($entity === null) {
			throw new \RuntimeException('Migration not found');
		}
		$entity->setStatus('running');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		try {
			if ($entity->getProvider() === 'onedrive') {
				$this->runOneDrive($entity);
			} else {
				throw new \RuntimeException('Provider not implemented: ' . $entity->getProvider());
			}
			$entity->setStatus('completed');
		} catch (\Throwable $e) {
			$this->logger->error('Cloud migrate failed: ' . $e->getMessage(), ['exception' => $e]);
			$entity->setStatus('failed');
			$entity->setErrorMessage($e->getMessage());
		}
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
	}

	private function runOneDrive(MigrationEntity $entity): void {
		$userId = $entity->getUserId();
		$folderId = $entity->getSourceItemId();
		$destBase = $entity->getDestPath();
		$dryRun = $entity->isDryRun();

		$files = iterator_to_array($this->graphClient->walkFolder($userId, $folderId));
		$total = count($files);
		$entity->setTotalFiles($total);
		$this->mapper->update($entity);

		$userFolder = $this->rootFolder->getUserFolder($userId);
		$copied = 0;
		foreach ($files as $file) {
			$targetPath = $destBase . '/' . $file['relativePath'];
			if (!$dryRun) {
				$this->ensureParentFolders($userFolder, $targetPath);
				$content = $this->graphClient->downloadItemContent($userId, $file['id']);
				$this->writeFile($userFolder, $targetPath, $content);
			}
			$copied++;
			$entity->setCopiedFiles($copied);
			$entity->setProgress($total > 0 ? (int)round(($copied / $total) * 100) : 100);
			$entity->setUpdatedAt(time());
			$this->mapper->update($entity);
		}
	}

	private function ensureParentFolders(\OCP\Files\Folder $userFolder, string $path): void {
		$parts = explode('/', dirname($path));
		$current = '';
		foreach ($parts as $part) {
			if ($part === '' || $part === '.') {
				continue;
			}
			$current = $current === '' ? $part : $current . '/' . $part;
			if (!$userFolder->nodeExists($current)) {
				$userFolder->newFolder($current);
			}
		}
	}

	private function writeFile(\OCP\Files\Folder $userFolder, string $path, string $content): void {
		if ($userFolder->nodeExists($path)) {
			$node = $userFolder->get($path);
			if ($node->getType() === \OCP\Files\FileInfo::TYPE_FILE) {
				$node->putContent($content);
				return;
			}
		}
		$userFolder->newFile($path, $content);
	}

	/**
	 * @return list<MigrationEntity>
	 */
	public function listForUser(string $userId): array {
		return $this->mapper->findByUser($userId);
	}

	public function getLatestForUser(string $userId): ?MigrationEntity {
		return $this->mapper->findLatestByUser($userId);
	}
}
