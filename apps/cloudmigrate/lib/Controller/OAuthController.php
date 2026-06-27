<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Controller;

use OCA\CloudMigrate\AppInfo\Application;
use OCA\CloudMigrate\Service\GraphClient;
use OCA\CloudMigrate\Service\TokenStore;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\RedirectResponse;
use OCP\IRequest;
use OCP\ISession;
use OCP\IURLGenerator;
use OCP\IUserSession;
use OCP\Security\ISecureRandom;

class OAuthController extends Controller {
	public function __construct(
		string $appName,
		IRequest $request,
		private IUserSession $userSession,
		private TokenStore $tokenStore,
		private GraphClient $graphClient,
		private ISession $session,
		private ISecureRandom $random,
		private IURLGenerator $urlGenerator,
	) {
		parent::__construct($appName, $request);
	}

	/**
	 * Start OneDrive OAuth or handle redirect callback on the same path.
	 *
	 * @NoAdminRequired
	 * @NoCSRFRequired
	 */
	public function onedrive(string $code = '', string $state = '', string $error = '', string $error_description = ''): RedirectResponse {
		$index = $this->urlGenerator->linkToRoute(Application::APP_ID . '.page.index');

		if ($code !== '' || $error !== '') {
			return $this->handleCallback($index, $code, $state, $error, $error_description);
		}

		$user = $this->userSession->getUser();
		if ($user === null) {
			return new RedirectResponse($this->urlGenerator->linkToRoute('core.login.showLoginForm'));
		}
		if ($this->tokenStore->getAdminClientId() === '') {
			return new RedirectResponse($index);
		}
		$stateToken = $this->random->generate(32, ISecureRandom::CHAR_ALPHANUMERIC);
		$this->session->set('cloudmigrate_oauth_state', $stateToken);
		$this->session->set('cloudmigrate_oauth_user', $user->getUID());
		$url = $this->graphClient->getAuthorizationUrl($user->getUID(), $stateToken);
		return new RedirectResponse($url);
	}

	private function handleCallback(
		string $index,
		string $code,
		string $state,
		string $error,
		string $errorDescription,
	): RedirectResponse {
		if ($error !== '') {
			$this->session->set('cloudmigrate_flash', 'OneDrive authorization failed: ' . ($errorDescription ?: $error));
			return new RedirectResponse($index);
		}
		$expected = (string)$this->session->get('cloudmigrate_oauth_state');
		$userId = (string)$this->session->get('cloudmigrate_oauth_user');
		$this->session->remove('cloudmigrate_oauth_state');
		$this->session->remove('cloudmigrate_oauth_user');
		if ($expected === '' || !hash_equals($expected, $state) || $userId === '') {
			$this->session->set('cloudmigrate_flash', 'Invalid OAuth state; try connecting again.');
			return new RedirectResponse($index);
		}
		try {
			$this->graphClient->exchangeCode($userId, $code);
			$this->session->set('cloudmigrate_flash', 'OneDrive connected successfully.');
		} catch (\Throwable $e) {
			$this->session->set('cloudmigrate_flash', 'OneDrive connection failed: ' . $e->getMessage());
		}
		return new RedirectResponse($index);
	}
}
