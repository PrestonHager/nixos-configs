<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

use OCA\CloudMigrate\AppInfo\Application;
use OCP\Http\Client\IClientService;
use OCP\IConfig;
use OCP\IURLGenerator;
use Psr\Log\LoggerInterface;

class GraphClient {
	private const GRAPH_BASE = 'https://graph.microsoft.com/v1.0';
	private const AUTH_BASE = 'https://login.microsoftonline.com';

	private const OAUTH_ROUTE_PATH = '/apps/cloudmigrate/oauth/onedrive';

	/** @var list<int> */
	private const RETRYABLE_STATUS = [429, 502, 503, 504];
	private const MAX_ATTEMPTS = 8;
	private const BASE_DELAY_MS = 1000;
	private const MAX_DELAY_MS = 60000;

	public function __construct(
		private TokenStore $tokenStore,
		private IClientService $clientService,
		private IURLGenerator $urlGenerator,
		private IConfig $config,
		private LoggerInterface $logger,
	) {
	}

	public function getAuthorizationUrl(string $userId, string $state): string {
		$clientId = $this->tokenStore->getAdminClientId();
		$tenant = $this->tokenStore->getAdminTenant();
		$redirectUri = $this->getRedirectUri();
		$this->logger->info('OneDrive OAuth authorization redirect_uri=' . $redirectUri, ['app' => Application::APP_ID]);
		$params = http_build_query([
			'client_id' => $clientId,
			'response_type' => 'code',
			'redirect_uri' => $redirectUri,
			'response_mode' => 'query',
			'scope' => 'offline_access User.Read Files.Read',
			'state' => $state,
		]);
		return self::AUTH_BASE . '/' . rawurlencode($tenant) . '/oauth2/v2.0/authorize?' . $params;
	}

	public function exchangeCode(string $userId, string $code): array {
		$tenant = $this->tokenStore->getAdminTenant();
		$url = self::AUTH_BASE . '/' . rawurlencode($tenant) . '/oauth2/v2.0/token';
		$client = $this->clientService->newClient();
		$body = [
			'client_id' => $this->tokenStore->getAdminClientId(),
			'grant_type' => 'authorization_code',
			'code' => $code,
			'redirect_uri' => $this->getRedirectUri(),
			'scope' => 'offline_access User.Read Files.Read',
		];
		$secret = $this->tokenStore->getAdminClientSecret();
		if ($secret !== '') {
			$body['client_secret'] = $secret;
		}
		$response = $client->post($url, ['body' => $body]);
		$data = json_decode($response->getBody(), true, 512, JSON_THROW_ON_ERROR);
		if (!isset($data['access_token'])) {
			throw new \RuntimeException('Token exchange failed: ' . ($data['error_description'] ?? 'unknown'));
		}
		$data['obtained_at'] = time();
		$this->tokenStore->storeOneDriveToken($userId, $data);
		return $data;
	}

	public function refreshTokenIfNeeded(string $userId): string {
		$token = $this->tokenStore->getOneDriveToken($userId);
		if ($token === null) {
			throw new \RuntimeException('OneDrive not connected');
		}
		$expiresAt = ($token['obtained_at'] ?? 0) + (int)($token['expires_in'] ?? 3600) - 120;
		if (time() < $expiresAt) {
			return $token['access_token'];
		}
		if (empty($token['refresh_token'])) {
			throw new \RuntimeException('OneDrive refresh token missing; reconnect account');
		}
		$tenant = $this->tokenStore->getAdminTenant();
		$url = self::AUTH_BASE . '/' . rawurlencode($tenant) . '/oauth2/v2.0/token';
		$client = $this->clientService->newClient();
		$body = [
			'client_id' => $this->tokenStore->getAdminClientId(),
			'grant_type' => 'refresh_token',
			'refresh_token' => $token['refresh_token'],
			'scope' => 'offline_access User.Read Files.Read',
		];
		$secret = $this->tokenStore->getAdminClientSecret();
		if ($secret !== '') {
			$body['client_secret'] = $secret;
		}
		$response = $client->post($url, ['body' => $body]);
		$data = json_decode($response->getBody(), true, 512, JSON_THROW_ON_ERROR);
		if (!isset($data['access_token'])) {
			throw new \RuntimeException('Token refresh failed');
		}
		$data['refresh_token'] = $data['refresh_token'] ?? $token['refresh_token'];
		$data['obtained_at'] = time();
		$this->tokenStore->storeOneDriveToken($userId, $data);
		return $data['access_token'];
	}

	/**
	 * @return list<array{id: string, name: string, path: string, folder: bool, size: int}>
	 */
	public function listChildren(string $userId, ?string $itemId = null): array {
		$accessToken = $this->refreshTokenIfNeeded($userId);
		$endpoint = $itemId === null
			? self::GRAPH_BASE . '/me/drive/root/children'
			: self::GRAPH_BASE . '/me/drive/items/' . rawurlencode($itemId) . '/children';
		return $this->fetchAllChildren($accessToken, $endpoint);
	}

	/**
	 * Resolve a drive item by path relative to the OneDrive root (e.g. Documents/Reports).
	 *
	 * @return array{id: string, name: string, path: string, folder: bool, size: int}
	 */
	public function resolvePath(string $userId, string $relativePath): array {
		$normalized = PathValidator::normalizeOneDrivePath($relativePath);
		$accessToken = $this->refreshTokenIfNeeded($userId);
		$url = $normalized === ''
			? self::GRAPH_BASE . '/me/drive/root'
			: self::GRAPH_BASE . '/me/drive/root:/' . $this->encodePathSegments($normalized) . ':';
		$response = $this->graphGet($accessToken, $url);
		$entry = json_decode($response->getBody(), true, 512, JSON_THROW_ON_ERROR);
		if (!isset($entry['id'])) {
			throw new \RuntimeException('OneDrive path not found: ' . $relativePath);
		}
		return $this->mapDriveItem($entry);
	}

	public function itemDisplayPath(array $item): string {
		return $this->parentPath($item);
	}

	/**
	 * @return list<array{id: string, name: string, path: string, folder: bool, size: int}>
	 */
	private function fetchAllChildren(string $accessToken, string $endpoint): array {
		$items = [];
		$url = $endpoint;
		while ($url !== '') {
			$response = $this->graphGet($accessToken, $url);
			$data = json_decode($response->getBody(), true, 512, JSON_THROW_ON_ERROR);
			foreach ($data['value'] ?? [] as $entry) {
				$items[] = $this->mapDriveItem($entry);
			}
			$url = (string)($data['@odata.nextLink'] ?? '');
		}
		return $items;
	}

	/**
	 * @param array<string, mixed> $entry
	 * @return array{id: string, name: string, path: string, folder: bool, size: int}
	 */
	private function mapDriveItem(array $entry): array {
		return [
			'id' => (string)$entry['id'],
			'name' => (string)($entry['name'] ?? ''),
			'path' => $this->parentPath($entry),
			'folder' => isset($entry['folder']),
			'size' => (int)($entry['size'] ?? 0),
		];
	}

	private function encodePathSegments(string $path): string {
		$segments = explode('/', $path);
		return implode('/', array_map('rawurlencode', $segments));
	}

	public function getDriveItem(string $userId, string $itemId): array {
		$accessToken = $this->refreshTokenIfNeeded($userId);
		$url = self::GRAPH_BASE . '/me/drive/items/' . rawurlencode($itemId);
		$response = $this->graphGet($accessToken, $url);
		return json_decode($response->getBody(), true, 512, JSON_THROW_ON_ERROR);
	}

	/**
	 * @param callable(int $attempt, int $maxAttempts, int $statusCode, int $delayMs): void|null $onRetry
	 */
	public function downloadItemContent(string $userId, string $itemId, ?callable $onRetry = null): string {
		$accessToken = $this->refreshTokenIfNeeded($userId);
		$url = self::GRAPH_BASE . '/me/drive/items/' . rawurlencode($itemId) . '/content';
		$response = $this->graphGet($accessToken, $url, $onRetry);
		return $response->getBody();
	}

	/**
	 * GET against Graph with retries for throttling / transient upstream errors.
	 *
	 * @param callable(int $attempt, int $maxAttempts, int $statusCode, int $delayMs): void|null $onRetry
	 */
	private function graphGet(string $accessToken, string $url, ?callable $onRetry = null): \OCP\Http\Client\IResponse {
		$client = $this->clientService->newClient();
		$options = [
			'headers' => ['Authorization' => 'Bearer ' . $accessToken],
		];
		$lastError = null;

		for ($attempt = 1; $attempt <= self::MAX_ATTEMPTS; $attempt++) {
			try {
				return $client->get($url, $options);
			} catch (\Throwable $e) {
				$lastError = $e;
				$status = $this->extractHttpStatus($e);
				if ($status === null || !in_array($status, self::RETRYABLE_STATUS, true) || $attempt >= self::MAX_ATTEMPTS) {
					if ($status !== null && in_array($status, self::RETRYABLE_STATUS, true)) {
						throw new \RuntimeException(
							'OneDrive Graph request failed after ' . self::MAX_ATTEMPTS
							. ' attempts (HTTP ' . $status . '): ' . $e->getMessage(),
							(int)$status,
							$e,
						);
					}
					throw $e;
				}

				$delayMs = $this->computeBackoffMs($attempt, $this->extractRetryAfterMs($e));
				$this->logger->warning(
					'cloudmigrate: Graph HTTP ' . $status . ' on attempt ' . $attempt
					. '/' . self::MAX_ATTEMPTS . ', retrying in ' . $delayMs . 'ms',
					['app' => Application::APP_ID],
				);
				if ($onRetry !== null) {
					$onRetry($attempt, self::MAX_ATTEMPTS, $status, $delayMs);
				}
				usleep($delayMs * 1000);
			}
		}

		throw $lastError ?? new \RuntimeException('OneDrive Graph request failed');
	}

	private function extractHttpStatus(\Throwable $e): ?int {
		if (method_exists($e, 'getResponse')) {
			try {
				$response = $e->getResponse();
				if ($response !== null && method_exists($response, 'getStatusCode')) {
					return (int)$response->getStatusCode();
				}
			} catch (\Throwable) {
				// fall through to message parse
			}
		}
		if (preg_match('/\b(429|502|503|504)\b/', $e->getMessage(), $m)) {
			return (int)$m[1];
		}
		return null;
	}

	private function extractRetryAfterMs(\Throwable $e): ?int {
		if (!method_exists($e, 'getResponse')) {
			return null;
		}
		try {
			$response = $e->getResponse();
		} catch (\Throwable) {
			return null;
		}
		if ($response === null) {
			return null;
		}

		$header = null;
		if (method_exists($response, 'getHeader')) {
			$raw = $response->getHeader('Retry-After');
			if (is_array($raw)) {
				$header = $raw[0] ?? null;
			} elseif (is_string($raw) && $raw !== '') {
				$header = $raw;
			}
		}
		if (($header === null || $header === '') && method_exists($response, 'getHeaderLine')) {
			$header = $response->getHeaderLine('Retry-After');
		}
		if (!is_string($header) || $header === '') {
			return null;
		}

		if (ctype_digit(trim($header))) {
			return max(0, (int)trim($header)) * 1000;
		}
		$when = strtotime($header);
		if ($when !== false) {
			return max(0, ($when - time()) * 1000);
		}
		return null;
	}

	private function computeBackoffMs(int $attempt, ?int $retryAfterMs): int {
		if ($retryAfterMs !== null && $retryAfterMs > 0) {
			// Small jitter on top of server-provided wait so parallel clients don't sync up.
			$jitter = random_int(0, 250);
			return min(self::MAX_DELAY_MS, $retryAfterMs + $jitter);
		}
		$exp = self::BASE_DELAY_MS * (2 ** max(0, $attempt - 1));
		$capped = min(self::MAX_DELAY_MS, $exp);
		$jitter = random_int(0, (int)max(1, $capped / 4));
		return min(self::MAX_DELAY_MS, $capped + $jitter);
	}

	/**
	 * @return \Generator<int, array{id: string, name: string, relativePath: string, size: int}>
	 */
	public function walkFolder(string $userId, string $folderId, string $basePath = ''): \Generator {
		$children = $this->listChildren($userId, $folderId);
		foreach ($children as $child) {
			$rel = ltrim($basePath . '/' . $child['name'], '/');
			if ($child['folder']) {
				yield from $this->walkFolder($userId, $child['id'], $rel);
			} else {
				yield [
					'id' => $child['id'],
					'name' => $child['name'],
					'relativePath' => $rel,
					'size' => $child['size'],
				];
			}
		}
	}

	public function getRedirectUri(): string {
		$overrideBase = $this->tokenStore->getAdminRedirectUriBase();
		if ($overrideBase !== '') {
			return rtrim($overrideBase, '/') . self::OAUTH_ROUTE_PATH;
		}

		$route = $this->urlGenerator->linkToRoute(Application::APP_ID . '.oauth.onedrive');
		if ($route !== '' && str_contains($route, '/oauth/onedrive')) {
			return $this->urlGenerator->getAbsoluteURL($route);
		}

		$base = rtrim($this->config->getSystemValueString('overwrite.cli.url'), '/');
		if ($base !== '') {
			return $base . self::OAUTH_ROUTE_PATH;
		}

		return $this->urlGenerator->linkToRouteAbsolute(Application::APP_ID . '.oauth.onedrive');
	}

	/**
	 * @return list<string> URIs to register in Azure (primary + index.php variant).
	 */
	public function getRedirectUriCandidates(): array {
		$primary = $this->getRedirectUri();
		$candidates = [$primary];
		if (str_contains($primary, '/index.php/apps/')) {
			$alternate = str_replace('/index.php/apps/', '/apps/', $primary);
		} else {
			$alternate = preg_replace('#^(https?://[^/]+)/apps/#', '$1/index.php/apps/', $primary);
		}
		if (is_string($alternate) && $alternate !== $primary) {
			$candidates[] = $alternate;
		}
		return array_values(array_unique($candidates));
	}

	private function parentPath(array $entry): string {
		$parent = $entry['parentReference']['path'] ?? '';
		$name = $entry['name'] ?? '';
		if (str_contains($parent, ':')) {
			$parent = substr($parent, strpos($parent, ':') + 1);
		}
		return trim($parent . '/' . $name, '/');
	}
}
