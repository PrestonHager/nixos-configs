<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCA\CloudMigrate\Db\MigrationEntity;
use OCA\CloudMigrate\Db\MigrationMapper;
use Psr\Log\LoggerInterface;

/**
 * Tracks worker/rclone PIDs on disk and handles cancel/pause signals.
 */
class JobControl {
	private const STALE_RUNNING_SECONDS = 120;
	private const STALE_QUEUED_SECONDS = 1800;

	public function __construct(
		private MigrationMapper $mapper,
		private LoggerInterface $logger,
	) {
	}

	public function statePath(int $migrationId): string {
		return sys_get_temp_dir() . '/cloudmigrate-job-' . $migrationId . '.json';
	}

	public function registerWorker(int $migrationId, int $pid): void {
		$this->writeState($migrationId, ['worker_pid' => $pid, 'rclone_pid' => null, 'started_at' => time()]);
	}

	public function registerRclone(int $migrationId, int $pid): void {
		$state = $this->readState($migrationId) ?? ['worker_pid' => getmypid(), 'started_at' => time()];
		$state['rclone_pid'] = $pid;
		$this->writeState($migrationId, $state);
	}

	public function clear(int $migrationId): void {
		$path = $this->statePath($migrationId);
		if (is_file($path)) {
			@unlink($path);
		}
	}

	public function isProcessAlive(?int $pid): bool {
		if ($pid === null || $pid <= 0) {
			return false;
		}
		if (function_exists('posix_kill')) {
			return @posix_kill($pid, 0);
		}
		$procPath = '/proc/' . $pid;
		return is_dir($procPath);
	}

	public function killWorker(int $migrationId): void {
		$state = $this->readState($migrationId);
		$pid = isset($state['worker_pid']) ? (int)$state['worker_pid'] : 0;
		if ($pid > 0 && $this->isProcessAlive($pid)) {
			$this->signalProcess($pid, 15);
		}
	}

	public function killRclone(int $migrationId): void {
		$state = $this->readState($migrationId);
		$pid = isset($state['rclone_pid']) ? (int)$state['rclone_pid'] : 0;
		if ($pid > 0 && $this->isProcessAlive($pid)) {
			$this->signalProcess($pid, 15);
			usleep(500000);
			if ($this->isProcessAlive($pid)) {
				$this->signalProcess($pid, 9);
			}
		}
	}

	public function pauseRclone(int $migrationId): void {
		$state = $this->readState($migrationId);
		$pid = isset($state['rclone_pid']) ? (int)$state['rclone_pid'] : 0;
		if ($pid > 0 && $this->isProcessAlive($pid)) {
			$this->signalProcess($pid, 19); // SIGSTOP
		}
	}

	public function resumeRclone(int $migrationId): void {
		$state = $this->readState($migrationId);
		$pid = isset($state['rclone_pid']) ? (int)$state['rclone_pid'] : 0;
		if ($pid > 0 && $this->isProcessAlive($pid)) {
			$this->signalProcess($pid, 18); // SIGCONT
		}
	}

	/**
	 * Mark jobs that lost their worker after a reboot or crash.
	 *
	 * @param list<MigrationEntity> $migrations
	 * @return list<MigrationEntity>
	 */
	public function reconcileStaleJobs(array $migrations): array {
		$result = [];
		foreach ($migrations as $entity) {
			$reconciled = $this->reconcileOne($entity);
			$result[] = $reconciled ?? $entity;
		}
		return $result;
	}

	public function reconcileOne(MigrationEntity $entity): ?MigrationEntity {
		$status = $entity->getStatus();
		if ($status === 'running') {
			return $this->reconcileRunning($entity);
		}
		if ($status === 'queued') {
			return $this->reconcileQueued($entity);
		}
		return null;
	}

	private function reconcileRunning(MigrationEntity $entity): ?MigrationEntity {
		$state = $this->readState($entity->getId());
		$workerPid = $entity->getWorkerPid();
		if ($state !== null && isset($state['worker_pid'])) {
			$workerPid = (int)$state['worker_pid'];
		}
		$alive = $this->isProcessAlive($workerPid);
		if ($alive) {
			return null;
		}
		$staleByTime = (time() - $entity->getUpdatedAt()) > self::STALE_RUNNING_SECONDS;
		if ($workerPid !== null && $workerPid > 0) {
			return $this->markInterrupted($entity);
		}
		if ($staleByTime) {
			return $this->markInterrupted($entity);
		}
		return null;
	}

	private function markInterrupted(MigrationEntity $entity): MigrationEntity {
		$entity->setStatus('failed');
		$entity->setPhase('');
		$entity->setStatusText('');
		$entity->setWorkerPid(null);
		$entity->setErrorMessage('Interrupted by server restart or worker crash');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		$this->clear($entity->getId());
		$this->logger->info('cloudmigrate: marked stale running job ' . $entity->getId() . ' as failed');
		return $entity;
	}

	private function reconcileQueued(MigrationEntity $entity): ?MigrationEntity {
		if ((time() - $entity->getCreatedAt()) < self::STALE_QUEUED_SECONDS) {
			return null;
		}
		$entity->setStatus('failed');
		$entity->setPhase('');
		$entity->setStatusText('');
		$entity->setErrorMessage('Job was queued too long without starting. Try starting a new migration.');
		$entity->setUpdatedAt(time());
		$this->mapper->update($entity);
		$this->clear($entity->getId());
		return $entity;
	}

	private function signalProcess(int $pid, int $signal): void {
		if (function_exists('posix_kill')) {
			@posix_kill($pid, $signal);
			return;
		}
		$sig = match ($signal) {
			15 => 'TERM',
			9 => 'KILL',
			19 => 'STOP',
			18 => 'CONT',
			default => null,
		};
		if ($sig !== null) {
			$process = new \Symfony\Component\Process\Process(['kill', '-' . $sig, (string)$pid]);
			$process->setTimeout(5);
			$process->run();
		}
	}

	/**
	 * @return array<string, mixed>|null
	 */
	private function readState(int $migrationId): ?array {
		$path = $this->statePath($migrationId);
		if (!is_file($path)) {
			return null;
		}
		$raw = file_get_contents($path);
		if ($raw === false || trim($raw) === '') {
			return null;
		}
		$data = json_decode($raw, true);
		return is_array($data) ? $data : null;
	}

	/**
	 * @param array<string, mixed> $state
	 */
	private function writeState(int $migrationId, array $state): void {
		$path = $this->statePath($migrationId);
		file_put_contents($path, json_encode($state, JSON_THROW_ON_ERROR), LOCK_EX);
		chmod($path, 0600);
	}
}
