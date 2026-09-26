<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\BackgroundJob;

use OCA\CloudMigrate\Service\MigrationService;
use OCP\AppFramework\Utility\ITimeFactory;
use OCP\BackgroundJob\QueuedJob;

class MigrationJob extends QueuedJob {
	public function __construct(
		ITimeFactory $time,
		private MigrationService $migrationService,
	) {
		parent::__construct($time);
	}

	protected function run($argument): void {
		$migrationId = (int)($argument['migrationId'] ?? 0);
		if ($migrationId <= 0) {
			return;
		}
		$this->migrationService->runMigration($migrationId);
	}
}
