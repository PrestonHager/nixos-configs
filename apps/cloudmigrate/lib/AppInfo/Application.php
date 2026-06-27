<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\AppInfo;

use OCA\CloudMigrate\BackgroundJob\MigrationJob;
use OCA\CloudMigrate\Command\MigrateCommand;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\BackgroundJob\IJobList;

class Application extends App implements IBootstrap {
	public const APP_ID = 'cloudmigrate';

	public function __construct() {
		parent::__construct(self::APP_ID);
	}

	public function register(IRegistrationContext $context): void {
		$context->registerCommand(MigrateCommand::class);
	}

	public function boot(IBootContext $context): void {
		$jobList = $context->getAppContainer()->get(IJobList::class);
		$jobList->add(MigrationJob::class);
	}
}
