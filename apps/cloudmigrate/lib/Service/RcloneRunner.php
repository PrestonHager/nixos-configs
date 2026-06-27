<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCP\IConfig;
use Psr\Log\LoggerInterface;
use Symfony\Component\Process\Process;

/**
 * Runs rclone with ephemeral per-user iCloud config (Apple ID + app-specific password).
 */
class RcloneRunner {
	private const REMOTE = 'icloud';

	public function __construct(
		private TokenStore $tokenStore,
		private IConfig $config,
		private LoggerInterface $logger,
	) {
	}

	public function isAvailable(): bool {
		$binary = $this->getBinaryPath();
		return is_executable($binary);
	}

	public function getBinaryPath(): string {
		$configured = trim($this->tokenStore->getAdminRclonePath());
		if ($configured !== '') {
			return $configured;
		}
		foreach (['/usr/local/bin/rclone', '/usr/bin/rclone', 'rclone'] as $candidate) {
			if ($candidate === 'rclone' || is_executable($candidate)) {
				return $candidate;
			}
		}
		return 'rclone';
	}

	/**
	 * @return list<array{id: string, name: string, path: string, folder: bool, size: int}>
	 */
	public function listFolders(string $userId, string $parentPath = ''): array {
		$configPath = $this->createTempConfig($userId);
		try {
			$remote = $this->remotePath($parentPath);
			$output = $this->runJson([
				'lsjson',
				$remote,
				'--dirs-only',
				'--max-depth',
				'1',
			], $configPath);
			$entries = json_decode($output, true, 512, JSON_THROW_ON_ERROR);
			if (!is_array($entries)) {
				return [];
			}
			$base = trim($parentPath, '/');
			$folders = [];
			foreach ($entries as $entry) {
				if (!is_array($entry) || !($entry['IsDir'] ?? false)) {
					continue;
				}
				$name = (string)($entry['Name'] ?? '');
				if ($name === '') {
					continue;
				}
				$path = $base === '' ? $name : $base . '/' . $name;
				$folders[] = [
					'id' => $path,
					'name' => $name,
					'path' => $path,
					'folder' => true,
					'size' => 0,
				];
			}
			usort($folders, static fn (array $a, array $b): int => strcasecmp($a['name'], $b['name']));
			return $folders;
		} finally {
			$this->removeTempConfig($configPath);
		}
	}

	/**
	 * @return list<array{path: string, size: int}>
	 */
	public function listFilesRecursive(string $userId, string $sourcePath): array {
		$configPath = $this->createTempConfig($userId);
		try {
			$remote = $this->remotePath($sourcePath);
			$output = $this->runJson([
				'lsjson',
				$remote,
				'-R',
				'--files-only',
			], $configPath);
			$entries = json_decode($output, true, 512, JSON_THROW_ON_ERROR);
			if (!is_array($entries)) {
				return [];
			}
			$prefix = trim($sourcePath, '/');
			$files = [];
			foreach ($entries as $entry) {
				if (!is_array($entry) || ($entry['IsDir'] ?? false)) {
					continue;
				}
				$name = (string)($entry['Name'] ?? '');
				$relPath = (string)($entry['Path'] ?? $name);
				if ($prefix !== '' && str_starts_with($relPath, $prefix . '/')) {
					$relPath = substr($relPath, strlen($prefix) + 1);
				}
				$files[] = [
					'path' => $relPath,
					'size' => (int)($entry['Size'] ?? 0),
				];
			}
			return $files;
		} finally {
			$this->removeTempConfig($configPath);
		}
	}

	public function copyToLocal(string $userId, string $sourcePath, string $localDestDir, bool $dryRun): void {
		$configPath = $this->createTempConfig($userId);
		try {
			if (!is_dir($localDestDir) && !$dryRun) {
				if (!mkdir($localDestDir, 0770, true) && !is_dir($localDestDir)) {
					throw new \RuntimeException('Could not create destination directory: ' . $localDestDir);
				}
			}
			$remote = $this->remotePath($sourcePath);
			$args = [
				'copy',
				$remote,
				$localDestDir,
				'--transfers=4',
				'--checkers=8',
				'--retries=5',
				'--low-level-retries=10',
			];
			if ($dryRun) {
				$args[] = '--dry-run';
			}
			$this->runProcess($args, $configPath, 3600);
		} finally {
			$this->removeTempConfig($configPath);
		}
	}

	public function resolveUserFilesPath(string $userId, string $destPath): string {
		$dataDir = rtrim((string)$this->config->getSystemValue('datadirectory', '/var/www/html/data'), '/');
		return $dataDir . '/' . $userId . '/files/' . trim($destPath, '/');
	}

	public function scanUserFiles(string $userId, string $destPath): void {
		$scanPath = $userId . '/files/' . trim($destPath, '/');
		$process = new Process([
			'php',
			'/var/www/html/occ',
			'files:scan',
			$userId,
			'--path=' . $scanPath,
		]);
		$process->setTimeout(3600);
		$process->run();
		if (!$process->isSuccessful()) {
			$this->logger->warning('cloudmigrate files:scan failed: ' . $process->getErrorOutput());
		}
	}

	private function remotePath(string $path): string {
		$trimmed = trim($path, '/');
		return $trimmed === '' ? self::REMOTE . ':' : self::REMOTE . ':' . $trimmed;
	}

	private function createTempConfig(string $userId): string {
		$appleId = $this->tokenStore->getIcloudAppleId($userId);
		$password = $this->tokenStore->getIcloudAppPassword($userId);
		if ($appleId === null || $password === null) {
			throw new \RuntimeException('iCloud credentials not configured');
		}
		$dir = sys_get_temp_dir() . '/cloudmigrate-' . bin2hex(random_bytes(8));
		if (!mkdir($dir, 0700, true) && !is_dir($dir)) {
			throw new \RuntimeException('Could not create temp config directory');
		}
		$configPath = $dir . '/rclone.conf';
		$ini = "[icloud]\n"
			. "type = icloud\n"
			. 'apple_id = ' . $this->iniEscape($appleId) . "\n"
			. 'password = ' . $this->iniEscape($password) . "\n";
		if (file_put_contents($configPath, $ini) === false) {
			throw new \RuntimeException('Could not write rclone config');
		}
		chmod($configPath, 0600);
		return $configPath;
	}

	private function removeTempConfig(string $configPath): void {
		$dir = dirname($configPath);
		if (is_file($configPath)) {
			@unlink($configPath);
		}
		if (is_dir($dir)) {
			@rmdir($dir);
		}
	}

	private function iniEscape(string $value): string {
		if (preg_match('/[\s#"\'=]/', $value) === 1) {
			return '"' . str_replace(['\\', '"'], ['\\\\', '\\"'], $value) . '"';
		}
		return $value;
	}

	/**
	 * @param list<string> $args
	 */
	private function runJson(array $args, string $configPath): string {
		$process = $this->buildProcess($args, $configPath, 600);
		$process->run();
		if (!$process->isSuccessful()) {
			$err = trim($process->getErrorOutput() . "\n" . $process->getOutput());
			throw new \RuntimeException('rclone failed: ' . ($err !== '' ? $err : 'exit ' . $process->getExitCode()));
		}
		return $process->getOutput();
	}

	/**
	 * @param list<string> $args
	 */
	private function runProcess(array $args, string $configPath, int $timeout): void {
		$process = $this->buildProcess($args, $configPath, $timeout);
		$process->run();
		if (!$process->isSuccessful()) {
			$err = trim($process->getErrorOutput() . "\n" . $process->getOutput());
			throw new \RuntimeException('rclone failed: ' . ($err !== '' ? $err : 'exit ' . $process->getExitCode()));
		}
	}

	/**
	 * @param list<string> $args
	 */
	private function buildProcess(array $args, string $configPath, int $timeout): Process {
		$cmd = array_merge([$this->getBinaryPath()], $args);
		$process = new Process($cmd);
		$process->setTimeout($timeout);
		$env = ['RCLONE_CONFIG' => $configPath];
		$process->setEnv($env);
		return $process;
	}
}
