<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Settings;

use OCP\IL10N;
use OCP\IURLGenerator;
use OCP\Settings\ISection;

class AdminSection implements ISection {
	public function __construct(
		private IL10N $l10n,
		private IURLGenerator $urlGenerator,
	) {
	}

	public function getID(): string {
		return 'cloudmigrate';
	}

	public function getName(): string {
		return $this->l10n->t('Cloud Migrate');
	}

	public function getPriority(): int {
		return 80;
	}

	public function getIcon(): string {
		return $this->urlGenerator->imagePath('cloudmigrate', 'app.svg');
	}
}
