<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCP\IConfig;
use Psr\Log\LoggerInterface;
use Symfony\Component\Process\Process;

/**
 * Runs rclone with ephemeral per-user iclouddrive config (Apple ID + trust token).
 */
class RcloneRunner {
	public const REMOTE = 'icloud';
	public const BACKEND = 'iclouddrive';
	private const LSJSON_TIMEOUT = 3600;

	public function __construct(
		private TokenStore $tokenStore,
		private IConfig $config,
		private JobControl $jobControl,
		private LoggerInterface $logger,
	) {
	}

	public function isAvailable(): bool {
		$binary = $this->getBinaryPath();
		if (!is_executable($binary)) {
			return false;
		}
		$process = new Process([$binary, 'help', 'backends']);
		$process->setTimeout(30);
		$process->run();
		return $process->isSuccessful()
			&& str_contains($process->getOutput(), self::BACKEND);
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
			], $configPath, 120);
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
	 * Walk iCloud Drive incrementally so large libraries report scan progress.
	 *
	 * @param callable(int $count, string $currentPath): void|null $onProgress
	 * @param callable(): void|null $shouldContinue returns false to abort
	 * @return list<array{path: string, size: int}>
	 */
	public function listFilesRecursive(
		string $userId,
		string $sourcePath,
		?callable $onProgress = null,
		?callable $shouldContinue = null,
	): array {
		$configPath = $this->createTempConfig($userId);
		try {
			$prefix = trim($sourcePath, '/');
			$files = [];
			$this->walkDirectory(
				$configPath,
				$prefix,
				$prefix,
				$files,
				$onProgress,
				$shouldContinue,
			);
			return $files;
		} finally {
			$this->removeTempConfig($configPath);
		}
	}

	/**
	 * @param list<array{path: string, size: int}> $files
	 */
	private function walkDirectory(
		string $configPath,
		string $rootPrefix,
		string $dirPath,
		array &$files,
		?callable $onProgress,
		?callable $shouldContinue,
	): void {
		if ($shouldContinue !== null && $shouldContinue() === false) {
			return;
		}
		$remote = $this->remotePath($dirPath);
		$output = $this->runJson([
			'lsjson',
			$remote,
			'--max-depth',
			'1',
		], $configPath, self::LSJSON_TIMEOUT);
		$entries = json_decode($output, true, 512, JSON_THROW_ON_ERROR);
		if (!is_array($entries)) {
			return;
		}
		foreach ($entries as $entry) {
			if (!is_array($entry)) {
				continue;
			}
			$name = (string)($entry['Name'] ?? '');
			if ($name === '') {
				continue;
			}
			$entryPath = trim($dirPath === '' ? $name : $dirPath . '/' . $name, '/');
			if ($entry['IsDir'] ?? false) {
				$this->walkDirectory($configPath, $rootPrefix, $entryPath, $files, $onProgress, $shouldContinue);
				continue;
			}
			$relPath = $entryPath;
			if ($rootPrefix !== '' && str_starts_with($relPath, $rootPrefix . '/')) {
				$relPath = substr($relPath, strlen($rootPrefix) + 1);
			} elseif ($rootPrefix !== '' && $relPath === $rootPrefix) {
				$relPath = $name;
			}
			$files[] = [
				'path' => $relPath,
				'size' => (int)($entry['Size'] ?? 0),
			];
			if ($onProgress !== null) {
				$onProgress(count($files), $relPath);
			}
		}
	}

	/**
	 * @param callable(string $line): void|null $onOutput
	 * @param callable(): void|null $shouldContinue
	 */
	public function copyToLocal(
		string $userId,
		string $sourcePath,
		string $localDestDir,
		bool $dryRun,
		?int $migrationId = null,
		?callable $onOutput = null,
		?callable $shouldContinue = null,
	): void {
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
				'--stats=5s',
				'--stats-one-line',
			];
			if ($dryRun) {
				$args[] = '--dry-run';
			}
			$this->runProcessStreaming($args, $configPath, 7200, $migrationId, $onOutput, $shouldContinue);
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
		$password = $this->tokenStore->getIcloudPassword($userId);
		if ($appleId === null || $password === null) {
			throw new \RuntimeException('iCloud credentials not configured');
		}
		if (!$this->tokenStore->hasIcloudSession($userId)) {
			throw new \RuntimeException('Complete iCloud sign-in (2FA) before using rclone. Use Sign in in Cloud Migrate or run occ cloudmigrate:icloud-auth.');
		}
		$session = $this->tokenStore->getIcloudSession($userId);
		$dir = sys_get_temp_dir() . '/cloudmigrate-' . bin2hex(random_bytes(8));
		if (!mkdir($dir, 0700, true) && !is_dir($dir)) {
			throw new \RuntimeException('Could not create temp config directory');
		}
		$configPath = $dir . '/rclone.conf';
		$obscuredPassword = $this->obscurePassword($password);
		$ini = '[' . self::REMOTE . "]\n"
			. 'type = ' . self::BACKEND . "\n"
			. "service = drive\n"
			. 'apple_id = ' . $this->iniEscape($appleId) . "\n"
			. 'password = ' . $this->iniEscape($obscuredPassword) . "\n";
		if ($session !== null) {
			$trustToken = (string)($session['trust_token'] ?? '');
			if ($trustToken !== '') {
				$ini .= 'trust_token = ' . $this->iniEscape($trustToken) . "\n";
			}
			$cookies = (string)($session['cookies'] ?? '');
			if ($cookies !== '') {
				$ini .= 'cookies = ' . $this->iniEscape($cookies) . "\n";
			}
		}
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

	private function obscurePassword(string $password): string {
		$process = new Process([$this->getBinaryPath(), 'obscure', '-']);
		$process->setInput($password);
		$process->setTimeout(30);
		$process->run();
		if (!$process->isSuccessful()) {
			throw new \RuntimeException('rclone obscure failed: ' . trim($process->getErrorOutput()));
		}
		$obscured = trim($process->getOutput());
		if ($obscured === '') {
			throw new \RuntimeException('rclone obscure returned empty output');
		}
		return $obscured;
	}

	/**
	 * @param list<string> $args
	 */
	private function runJson(array $args, string $configPath, int $timeout): string {
		$process = $this->buildProcess($args, $configPath, $timeout);
		$process->run();
		if (!$process->isSuccessful()) {
			$err = trim($process->getErrorOutput() . "\n" . $process->getOutput());
			throw new \RuntimeException('rclone failed: ' . ($err !== '' ? $err : 'exit ' . $process->getExitCode()));
		}
		return $process->getOutput();
	}

	/**
	 * @param list<string> $args
	 * @param callable(string $line): void|null $onOutput
	 * @param callable(): void|null $shouldContinue
	 */
	private function runProcessStreaming(
		array $args,
		string $configPath,
		int $timeout,
		?int $migrationId,
		?callable $onOutput,
		?callable $shouldContinue,
	): void {
		$process = $this->buildProcess($args, $configPath, $timeout);
		$process->start();
		if ($migrationId !== null) {
			$this->jobControl->registerRclone($migrationId, $process->getPid() ?? 0);
		}
		$buffer = '';
		while ($process->isRunning()) {
			if ($shouldContinue !== null) {
				$shouldContinue();
			}
			$chunk = $process->getIncrementalOutput() . $process->getIncrementalErrorOutput();
			if ($chunk !== '') {
				$buffer .= $chunk;
				while (($pos = strpos($buffer, "\n")) !== false) {
					$line = rtrim(substr($buffer, 0, $pos), "\r");
					$buffer = substr($buffer, $pos + 1);
					if ($onOutput !== null && $line !== '') {
						$onOutput($line);
					}
				}
			}
			usleep(200000);
		}
		$tail = trim($buffer . $process->getOutput() . $process->getErrorOutput());
		if ($onOutput !== null && $tail !== '') {
			foreach (preg_split('/\r?\n/', $tail) ?: [] as $line) {
				if ($line !== '') {
					$onOutput($line);
				}
			}
		}
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
