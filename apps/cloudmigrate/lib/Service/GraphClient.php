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
		$client = $this->clientService->newClient();
		$url = $normalized === ''
			? self::GRAPH_BASE . '/me/drive/root'
			: self::GRAPH_BASE . '/me/drive/root:/' . $this->encodePathSegments($normalized) . ':';
		$response = $client->get($url, [
			'headers' => ['Authorization' => 'Bearer ' . $accessToken],
		]);
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
		$client = $this->clientService->newClient();
		$items = [];
		$url = $endpoint;
		while ($url !== '') {
			$response = $client->get($url, [
				'headers' => ['Authorization' => 'Bearer ' . $accessToken],
			]);
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
		$client = $this->clientService->newClient();
		$url = self::GRAPH_BASE . '/me/drive/items/' . rawurlencode($itemId);
		$response = $client->get($url, [
			'headers' => ['Authorization' => 'Bearer ' . $accessToken],
		]);
		return json_decode($response->getBody(), true, 512, JSON_THROW_ON_ERROR);
	}

	public function downloadItemContent(string $userId, string $itemId): string {
		$accessToken = $this->refreshTokenIfNeeded($userId);
		$client = $this->clientService->newClient();
		$url = self::GRAPH_BASE . '/me/drive/items/' . rawurlencode($itemId) . '/content';
		$response = $client->get($url, [
			'headers' => ['Authorization' => 'Bearer ' . $accessToken],
		]);
		return $response->getBody();
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
