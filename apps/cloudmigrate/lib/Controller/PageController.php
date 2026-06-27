<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Controller;

use OCA\CloudMigrate\AppInfo\Application;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\IRequest;
use OCP\ISession;
use OCP\IURLGenerator;
use OCP\Util;

class PageController extends Controller {
	public function __construct(
		string $appName,
		IRequest $request,
		private ISession $session,
		private IURLGenerator $urlGenerator,
	) {
		parent::__construct($appName, $request);
	}

	/**
	 * @NoAdminRequired
	 * @NoCSRFRequired
	 */
	public function index(): TemplateResponse {
		Util::addScript(Application::APP_ID, 'main');
		Util::addStyle(Application::APP_ID, 'main');
		$flash = (string)$this->session->get('cloudmigrate_flash');
		$this->session->remove('cloudmigrate_flash');
		return (new TemplateResponse(Application::APP_ID, 'index', [
			'flash' => $flash,
			'onedriveConnectUrl' => $this->urlGenerator->linkToRoute(Application::APP_ID . '.oauth.onedrive'),
		]))->renderAs('blank');
	}
}
