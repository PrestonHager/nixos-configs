<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCP\IConfig;
use Symfony\Component\Process\Process;

/**
 * Runs rclone config create/reconnect for iclouddrive (Apple ID + 2FA trust token).
 */
class RcloneAuthService {
	public const STATUS_NONE = 'none';
	public const STATUS_NEEDS_AUTH = 'needs_auth';
	public const STATUS_NEEDS_2FA = 'needs_2fa';
	public const STATUS_AUTHENTICATED = 'authenticated';

	private const REMOTE = 'icloud';

	public function __construct(
		private TokenStore $tokenStore,
		private RcloneRunner $rcloneRunner,
		private IConfig $config,
	) {
	}

	public function getAuthStatus(string $userId): string {
		if (!$this->tokenStore->isIcloudConfigured($userId)) {
			return self::STATUS_NONE;
		}
		if ($this->tokenStore->hasIcloudSession($userId)) {
			return self::STATUS_AUTHENTICATED;
		}
		return self::STATUS_NEEDS_AUTH;
	}

	/**
	 * @return array{status: string, state?: string, message: string, option?: array<string, mixed>}
	 */
	public function startAuth(string $userId): array {
		$this->assertCredentials($userId);
		$configPath = $this->prepareAuthConfig($userId);
		$credentials = $this->getCredentials($userId);

		$output = $this->runConfigCreate([
			'config', 'create', self::REMOTE, RcloneRunner::BACKEND,
			'service', 'drive',
			'apple_id', $credentials['appleId'],
			'password', $credentials['password'],
			'--non-interactive',
			'--obscure',
		], $configPath);

		return $this->handleConfigOutput($userId, $configPath, $output);
	}

	/**
	 * @return array{status: string, state?: string, message: string, option?: array<string, mixed>}
	 */
	public function continueAuth(string $userId, string $state, string $result): array {
		$this->assertCredentials($userId);
		$configPath = $this->getAuthConfigPath($userId);
		if (!is_file($configPath)) {
			throw new \RuntimeException('Sign-in session expired. Start iCloud sign-in again.');
		}
		$credentials = $this->getCredentials($userId);
		$result = trim($result);
		if ($result === '') {
			throw new \InvalidArgumentException('2FA code is required');
		}

		$output = $this->runConfigCreate([
			'config', 'create', self::REMOTE, RcloneRunner::BACKEND,
			'--continue',
			'--state', $state,
			'--result', $result,
			'service', 'drive',
			'apple_id', $credentials['appleId'],
			'password', $credentials['password'],
		], $configPath);

		return $this->handleConfigOutput($userId, $configPath, $output);
	}

	public function clearAuthState(string $userId): void {
		$this->tokenStore->clearIcloudSession($userId);
		$configPath = $this->getAuthConfigPath($userId);
		if (is_file($configPath)) {
			@unlink($configPath);
		}
	}

	public function getAuthConfigPath(string $userId): string {
		$dataDir = rtrim((string)$this->config->getSystemValue('datadirectory', '/var/www/html/data'), '/');
		$dir = $dataDir . '/' . $userId . '/.cloudmigrate';
		if (!is_dir($dir) && !mkdir($dir, 0700, true) && !is_dir($dir)) {
			throw new \RuntimeException('Could not create Cloud Migrate config directory');
		}
		return $dir . '/rclone.conf';
	}

	private function prepareAuthConfig(string $userId): string {
		$this->tokenStore->clearIcloudSession($userId);
		$configPath = $this->getAuthConfigPath($userId);
		if (is_file($configPath)) {
			@unlink($configPath);
		}
		return $configPath;
	}

	/**
	 * @param list<string> $args
	 */
	private function runConfigCreate(array $args, string $configPath): string {
		$cmd = array_merge([$this->rcloneRunner->getBinaryPath()], $args);
		$process = new Process($cmd);
		$process->setTimeout(180);
		$process->setEnv([
			'RCLONE_CONFIG' => $configPath,
			'HOME' => dirname($configPath),
		]);
		$process->run();

		$combined = trim($process->getOutput() . "\n" . $process->getErrorOutput());
		if (!$process->isSuccessful() && !$this->containsConfigJson($combined)) {
			throw new \RuntimeException($this->extractErrorMessage($combined));
		}
		return $combined;
	}

	/**
	 * @return array{status: string, state?: string, message: string, option?: array<string, mixed>}
	 */
	private function handleConfigOutput(string $userId, string $configPath, string $output): array {
		$payload = $this->parseConfigJson($output);
		if ($payload === null) {
			$this->importSessionFromConfig($userId, $configPath);
			return [
				'status' => self::STATUS_AUTHENTICATED,
				'message' => 'iCloud sign-in complete. Trust token stored (valid ~30 days).',
			];
		}

		$state = (string)($payload['State'] ?? $payload['state'] ?? '');
		if ($state === '') {
			$this->importSessionFromConfig($userId, $configPath);
			return [
				'status' => self::STATUS_AUTHENTICATED,
				'message' => 'iCloud sign-in complete. Trust token stored (valid ~30 days).',
			];
		}

		$option = $payload['Option'] ?? $payload['option'] ?? null;
		if ($state === '2fa_do' || (is_array($option) && ($option['Name'] ?? '') === 'config_2fa')) {
			return [
				'status' => self::STATUS_NEEDS_2FA,
				'state' => $state,
				'message' => 'Enter the 6-digit code from your trusted Apple device, or type sms to receive a text message.',
				'option' => is_array($option) ? $option : [],
			];
		}

		throw new \RuntimeException('Unexpected rclone config state: ' . $state);
	}

	public function importSessionFromConfig(string $userId, string $configPath): void {
		$process = new Process([
			$this->rcloneRunner->getBinaryPath(),
			'config',
			'dump',
		]);
		$process->setTimeout(30);
		$process->setEnv(['RCLONE_CONFIG' => $configPath]);
		$process->run();
		if (!$process->isSuccessful()) {
			throw new \RuntimeException('Could not read rclone config: ' . trim($process->getErrorOutput()));
		}

		/** @var array<string, array<string, mixed>> $dump */
		$dump = json_decode($process->getOutput(), true, 512, JSON_THROW_ON_ERROR);
		$remote = $dump[self::REMOTE] ?? null;
		if (!is_array($remote)) {
			throw new \RuntimeException('iCloud remote missing from rclone config after sign-in');
		}

		$trustToken = (string)($remote['trust_token'] ?? '');
		if ($trustToken === '') {
			throw new \RuntimeException('Sign-in did not produce a trust token. Complete 2FA and try again.');
		}

		$this->tokenStore->storeIcloudSession($userId, [
			'trust_token' => $trustToken,
			'cookies' => (string)($remote['cookies'] ?? ''),
			'authenticated_at' => time(),
		]);
	}

	/**
	 * @return array{appleId: string, password: string}
	 */
	private function getCredentials(string $userId): array {
		$appleId = $this->tokenStore->getIcloudAppleId($userId);
		$password = $this->tokenStore->getIcloudPassword($userId);
		if ($appleId === null || $password === null) {
			throw new \RuntimeException('iCloud credentials not configured');
		}
		return ['appleId' => $appleId, 'password' => $password];
	}

	private function assertCredentials(string $userId): void {
		if (!$this->tokenStore->isIcloudConfigured($userId)) {
			throw new \RuntimeException('Save Apple ID and password before signing in');
		}
		if (!$this->rcloneRunner->isAvailable()) {
			throw new \RuntimeException('rclone is not available on the server');
		}
	}

	private function containsConfigJson(string $output): bool {
		return $this->parseConfigJson($output) !== null;
	}

	/**
	 * @return array<string, mixed>|null
	 */
	private function parseConfigJson(string $output): ?array {
		foreach (array_reverse(preg_split('/\R/', $output) ?: []) as $line) {
			$line = trim($line);
			if ($line === '' || $line[0] !== '{') {
				continue;
			}
			try {
				/** @var array<string, mixed> $decoded */
				$decoded = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
				return $decoded;
			} catch (\JsonException) {
				continue;
			}
		}
		return null;
	}

	private function extractErrorMessage(string $output): string {
		foreach (preg_split('/\R/', $output) ?: [] as $line) {
			$line = trim($line);
			if (str_starts_with($line, 'Error:')) {
				return substr($line, 6);
			}
		}
		return $output !== '' ? $output : 'rclone config failed';
	}
}
