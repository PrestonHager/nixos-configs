<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCA\CloudMigrate\Db\MigrationEntity;
use OCA\CloudMigrate\Db\MigrationMapper;
use OCA\CloudMigrate\Exception\MigrationCancelledException;
use OCA\CloudMigrate\Exception\MigrationPausedException;
use OCP\BackgroundJob\IJobList;
use OCP\Files\IRootFolder;
use OCP\Files\NotPermittedException;
use Psr\Log\LoggerInterface;

class MigrationService {
	public const DEST_ONEDRIVE = 'Migrated/OneDrive';
	public const DEST_ICLOUD = 'Migrated/iCloud';
	public const DEST_ICLOUD_PHOTOS = 'Migrated/iCloud/Photos';

	public function __construct(
		private MigrationMapper $mapper,
		private IJobList $jobList,
		private GraphClient $graphClient,
		private RcloneRunner $rcloneRunner,
		private TokenStore $tokenStore,
		private IRootFolder $rootFolder,
		private JobControl $jobControl,
		private LoggerInterface $logger,
	) {
	}

	public function startOneDriveMigration(
		string $userId,
		string $folderId,
		string $sourceLabel,
		bool $dryRun,
		string $destBase = self::DEST_ONEDRIVE,
		string $destSubpath = '',
	): MigrationEntity {
		if (!$this->tokenStore->isOneDriveConnected($userId)) {
			throw new \RuntimeException('Connect OneDrive before starting migration');
		}

		if ($folderId === '' || $folderId === 'root') {
			$resolved = $this->graphClient->resolvePath($userId, '');
			$folderId = $resolved['id'];
		} else {
			$raw = $this->graphClient->getDriveItem($userId, $folderId);
			if (!isset($raw['folder'])) {
				throw new \RuntimeException('Source must be a folder');
			}
			$resolved = $raw;
		}

		$displayPath = $this->graphClient->itemDisplayPath($resolved);
		if ($displayPath === '') {
			$displayPath = 'OneDrive';
		}
		if ($sourceLabel !== '' && $sourceLabel !== '/') {
			$displayPath = $sourceLabel;
		}

		$destPath = PathValidator::normalizeDestPath($destBase, $destSubpath);

		$entity = $this->newQueuedEntity($userId, 'onedrive', $displayPath, $folderId, $destPath, $dryRun);
		$inserted = $this->mapper->insert($entity);
		$this->enqueue($inserted->getId());
		return $inserted;
	}

	public function startIcloudMigration(
		string $userId,
		string $sourcePath,
		string $sourceLabel,
		bool $dryRun,
		string $destPath = self::DEST_ICLOUD,
	): MigrationEntity {
		if (!$this->tokenStore->isIcloudConfigured($userId)) {
			throw new \RuntimeException('Connect iCloud before starting migration');
		}
		if (!$this->tokenStore->hasIcloudSession($userId)) {
			throw new \RuntimeException('Complete iCloud sign-in (2FA) before starting migration');
		}
		if (!$this->rcloneRunner->isAvailable()) {
			throw new \RuntimeException('rclone is not available on the server. Ask an administrator to install rclone for the Nextcloud container.');
		}
		$normalizedSource = PathValidator::normalizeOneDrivePath($sourcePath);
		$validatedDest = PathValidator::normalizeDestPath($destPath);
		$entity = $this->newQueuedEntity($userId, 'icloud', $sourceLabel, $normalizedSource, $validatedDest, $dryRun);
		$inserted = $this->mapper->insert($entity);
		$this->enqueue($inserted->getId());
		return $inserted;
	}

	public function runMigration(int $migrationId): void {
		$entity = $this->mapper->findById($migrationId);
		if ($entity === null) {
			throw new \RuntimeException('Migration not found');
		}
		if (in_array($entity->getStatus(), ['cancelled', 'completed', 'failed'], true)) {
			return;
		}

		$pid = getmypid() ?: null;
		$entity->setStatus('running');
		$entity->setWorkerPid($pid);
		$entity->setPhase('starting');
		$entity->setStatusText('Starting migration…');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		if ($pid !== null) {
			$this->jobControl->registerWorker($migrationId, $pid);
		}

		try {
			if ($entity->getProvider() === 'onedrive') {
				$this->runOneDrive($entity);
			} elseif ($entity->getProvider() === 'icloud') {
				$this->runIcloud($entity);
			} else {
				throw new \RuntimeException('Provider not implemented: ' . $entity->getProvider());
			}
			$entity->setStatus('completed');
			$entity->setPhase('done');
			$entity->setStatusText('Migration complete');
			$entity->setProgress(100);
		} catch (MigrationCancelledException $e) {
			$entity->setStatus('cancelled');
			$entity->setPhase('');
			$entity->setStatusText('Cancelled');
			$entity->setErrorMessage($e->getMessage() !== '' ? $e->getMessage() : 'Cancelled by user');
		} catch (MigrationPausedException $e) {
			$entity->setStatus('paused');
			$entity->setPhase('paused');
			$entity->setStatusText('Paused');
		} catch (\Throwable $e) {
			$this->logger->error('Cloud migrate failed: ' . $e->getMessage(), ['exception' => $e]);
			$entity->setStatus('failed');
			$entity->setPhase('');
			$entity->setStatusText('');
			$entity->setErrorMessage($e->getMessage());
		}
		$entity->setWorkerPid(null);
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		$this->jobControl->clear($migrationId);
	}

	public function cancelMigration(int $migrationId, string $userId): MigrationEntity {
		$entity = $this->requireOwned($migrationId, $userId);
		if (!in_array($entity->getStatus(), ['queued', 'running', 'paused'], true)) {
			throw new \RuntimeException('This migration cannot be cancelled');
		}
		$entity->setStatus('cancelled');
		$entity->setPhase('');
		$entity->setStatusText('Cancelled');
		$entity->setErrorMessage('Cancelled by user');
		$entity->setWorkerPid(null);
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		$this->jobControl->killRclone($migrationId);
		$this->jobControl->killWorker($migrationId);
		$this->jobControl->clear($migrationId);
		return $entity;
	}

	public function pauseMigration(int $migrationId, string $userId): MigrationEntity {
		$entity = $this->requireOwned($migrationId, $userId);
		if ($entity->getStatus() !== 'running') {
			throw new \RuntimeException('Only running migrations can be paused');
		}
		$entity->setStatus('paused');
		$entity->setPhase('paused');
		$entity->setStatusText('Paused by user');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		$this->jobControl->pauseRclone($migrationId);
		return $entity;
	}

	public function resumeMigration(int $migrationId, string $userId): MigrationEntity {
		$entity = $this->requireOwned($migrationId, $userId);
		if (!in_array($entity->getStatus(), ['paused', 'failed'], true)) {
			throw new \RuntimeException('Only paused or failed migrations can be resumed');
		}
		$entity->setStatus('queued');
		$entity->setPhase('queued');
		$entity->setStatusText('Queued to resume…');
		$entity->setErrorMessage(null);
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		$this->jobControl->resumeRclone($migrationId);
		$this->enqueue($migrationId);
		return $entity;
	}

	/**
	 * @return list<MigrationEntity>
	 */
	public function listForUser(string $userId): array {
		$migrations = $this->mapper->findByUser($userId);
		return $this->jobControl->reconcileStaleJobs($migrations);
	}

	public function getLatestForUser(string $userId): ?MigrationEntity {
		$list = $this->listForUser($userId);
		return $list[0] ?? null;
	}

	private function runOneDrive(MigrationEntity $entity): void {
		$userId = $entity->getUserId();
		$folderId = $entity->getSourceItemId();
		$destBase = $entity->getDestPath();
		$dryRun = $entity->isDryRun();
		$checkpoint = $entity->getCheckpoint() ?? '';
		$afterCheckpoint = $checkpoint === '';

		$entity->setPhase('scanning');
		$entity->setStatusText('Scanning OneDrive folders…');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		$files = [];
		$scanned = 0;
		foreach ($this->graphClient->walkFolder($userId, $folderId) as $file) {
			$this->assertActive($entity);
			$files[] = $file;
			$scanned++;
			if ($scanned % 25 === 0) {
				$entity->setCopiedFiles($scanned);
				$entity->setStatusText('Scanning… ' . $scanned . ' file(s) found');
				$entity->setUpdatedAt(time());
				$this->mapper->update($entity);
			}
		}

		$total = count($files);
		$entity->setTotalFiles($total);
		$entity->setCopiedFiles(0);
		$entity->setPhase('copying');
		$entity->setStatusText($total > 0 ? 'Copying 0/' . $total . ' files…' : 'No files to copy');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		if ($dryRun) {
			$entity->setCopiedFiles($total);
			$entity->setProgress(100);
			$entity->setStatusText('Dry run complete: ' . $total . ' file(s) found');
			return;
		}

		$userFolder = $this->rootFolder->getUserFolder($userId);
		$copied = 0;
		foreach ($files as $file) {
			$this->assertActive($entity);
			$rel = $file['relativePath'];
			if (!$afterCheckpoint) {
				$copied++;
				if ($rel === $checkpoint) {
					$afterCheckpoint = true;
					$entity->setCopiedFiles($copied);
					$entity->setProgress($total > 0 ? (int)round(($copied / $total) * 100) : 100);
					$entity->setStatusText('Resuming after ' . $copied . '/' . $total . ': ' . $rel);
					$entity->setUpdatedAt(time());
					$this->mapper->update($entity);
				} elseif ($copied % 100 === 0) {
					$entity->setCopiedFiles($copied);
					$entity->setProgress($total > 0 ? (int)round(($copied / $total) * 100) : 100);
					$entity->setStatusText('Resuming… catching up ' . $copied . '/' . $total);
					$entity->setUpdatedAt(time());
					$this->mapper->update($entity);
				}
				continue;
			}
			$targetPath = $destBase . '/' . $rel;
			$this->ensureParentFolders($userFolder, $targetPath);
			if ($userFolder->nodeExists($targetPath)) {
				$node = $userFolder->get($targetPath);
				if ($node->getType() === \OCP\Files\FileInfo::TYPE_FILE && $node->getSize() === $file['size']) {
					$copied++;
					$entity->setCheckpoint($rel);
					$entity->setCopiedFiles($copied);
					$entity->setProgress($total > 0 ? (int)round(($copied / $total) * 100) : 100);
					$entity->setStatusText('Copying ' . $copied . '/' . $total . ': ' . $rel . ' (skipped, already exists)');
					$entity->setUpdatedAt(time());
					$this->mapper->update($entity);
					continue;
				}
			}
			$content = $this->graphClient->downloadItemContent(
				$userId,
				$file['id'],
				function (int $attempt, int $maxAttempts, int $statusCode, int $delayMs) use ($entity, $copied, $total, $rel): void {
					$this->assertActive($entity);
					$waitSec = max(1, (int)ceil($delayMs / 1000));
					$entity->setStatusText(
						'Retrying download ' . ($copied + 1) . '/' . $total . ': ' . $rel
						. ' (HTTP ' . $statusCode . ', attempt ' . $attempt . '/' . $maxAttempts
						. ', waiting ' . $waitSec . 's)'
					);
					$entity->setUpdatedAt(time());
					$this->mapper->update($entity);
				},
			);
			$this->writeFile($userFolder, $targetPath, $content);
			$copied++;
			$entity->setCheckpoint($rel);
			$entity->setCopiedFiles($copied);
			$entity->setProgress($total > 0 ? (int)round(($copied / $total) * 100) : 100);
			$entity->setStatusText('Copying ' . $copied . '/' . $total . ': ' . $rel);
			$entity->setErrorMessage(null);
			$entity->setUpdatedAt(time());
			$this->mapper->update($entity);
		}
	}

	private function runIcloud(MigrationEntity $entity): void {
		$userId = $entity->getUserId();
		$sourcePath = $entity->getSourceItemId();
		$destPath = $entity->getDestPath();
		$dryRun = $entity->isDryRun();
		$migrationId = $entity->getId();

		$entity->setPhase('scanning');
		$entity->setStatusText('Scanning iCloud Drive…');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		$files = $this->rcloneRunner->listFilesRecursive(
			$userId,
			$sourcePath,
			function (int $count, string $currentPath) use ($entity): void {
				$this->assertActive($entity);
				$entity->setCopiedFiles($count);
				$entity->setStatusText('Scanning… ' . $count . ' file(s) found' . ($currentPath !== '' ? ' — ' . $currentPath : ''));
				$entity->setUpdatedAt(time());
				$this->mapper->update($entity);
			},
			function () use ($entity): void {
				$this->assertActive($entity);
			},
		);

		$total = count($files);
		$entity->setTotalFiles($total);
		$entity->setCopiedFiles(0);
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		if ($dryRun) {
			$entity->setCopiedFiles($total);
			$entity->setProgress(100);
			$entity->setPhase('done');
			$entity->setStatusText('Dry run complete: ' . $total . ' file(s) found');
			return;
		}

		$localDest = $this->rcloneRunner->resolveUserFilesPath($userId, $destPath);
		if ($sourcePath !== '') {
			$localDest .= '/' . $sourcePath;
		}

		$entity->setPhase('copying');
		$entity->setStatusText('Copying with rclone…');
		$entity->setProgress(0);
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		$this->rcloneRunner->copyToLocal(
			$userId,
			$sourcePath,
			$localDest,
			false,
			$migrationId,
			function (string $line) use ($entity, $total): void {
				$this->assertActive($entity);
				if (preg_match('/Transferred:\s+(\d+)\s*\/\s*(\d+)/', $line, $m)) {
					$done = (int)$m[1];
					$found = (int)$m[2];
					$denom = $total > 0 ? $total : max($found, 1);
					$entity->setCopiedFiles($done);
					$entity->setProgress(min(99, (int)round(($done / $denom) * 100)));
					$entity->setStatusText('Copying… ' . $done . '/' . $denom . ' transferred');
					$entity->setUpdatedAt(time());
					$this->mapper->update($entity);
				} elseif (preg_match('/Checks:\s+(\d+)/', $line, $m)) {
					$entity->setStatusText('Copying… checking files (' . $m[1] . ' checked)');
					$entity->setUpdatedAt(time());
					$this->mapper->update($entity);
				}
			},
			function () use ($entity): void {
				$this->assertActive($entity);
			},
		);

		$entity->setPhase('indexing');
		$entity->setStatusText('Indexing files in Nextcloud…');
		$entity->setProgress(95);
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);

		$this->rcloneRunner->scanUserFiles($userId, $destPath);

		$entity->setCopiedFiles($total);
		$entity->setProgress(100);
		$entity->setStatusText('Copy complete');
	}

	private function assertActive(MigrationEntity $entity): void {
		$fresh = $this->mapper->findById($entity->getId());
		if ($fresh === null) {
			throw new MigrationCancelledException('Migration removed');
		}
		$status = $fresh->getStatus();
		if ($status === 'cancelled') {
			throw new MigrationCancelledException('Cancelled by user');
		}
		if ($status === 'paused') {
			throw new MigrationPausedException('Paused by user');
		}
		$entity->setStatus($status);
	}

	private function newQueuedEntity(
		string $userId,
		string $provider,
		string $sourcePath,
		string $sourceItemId,
		string $destPath,
		bool $dryRun,
	): MigrationEntity {
		$entity = new MigrationEntity();
		$entity->setUserId($userId);
		$entity->setProvider($provider);
		$entity->setStatus('queued');
		$entity->setPhase('queued');
		$entity->setStatusText('Queued');
		$entity->setSourcePath($sourcePath);
		$entity->setSourceItemId($sourceItemId);
		$entity->setDestPath($destPath);
		$entity->setDryRun($dryRun);
		$entity->setProgress(0);
		$entity->setTotalFiles(0);
		$entity->setCopiedFiles(0);
		$entity->setCreatedAt(time());
		$entity->setUpdatedAt(time());
		return $entity;
	}

	private function enqueue(int $migrationId): void {
		$this->jobList->add(\OCA\CloudMigrate\BackgroundJob\MigrationJob::class, [
			'migrationId' => $migrationId,
		]);
	}

	private function requireOwned(int $migrationId, string $userId): MigrationEntity {
		$entity = $this->mapper->findById($migrationId);
		if ($entity === null || $entity->getUserId() !== $userId) {
			throw new \RuntimeException('Migration not found');
		}
		return $entity;
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
}
