<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Command;

use OCA\CloudMigrate\Service\MigrationService;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

class MigrateCommand extends Command {
	public function __construct(
		private MigrationService $migrationService,
	) {
		parent::__construct();
	}

	protected function configure(): void {
		$this
			->setName('cloudmigrate:run')
			->setDescription('Run a queued cloud migration by ID (normally handled by background job)')
			->addArgument('migration-id', InputArgument::REQUIRED, 'Migration row ID')
			->addOption('wait', null, InputOption::VALUE_NONE, 'Run synchronously in this process');
	}

	protected function execute(InputInterface $input, OutputInterface $output): int {
		$id = (int)$input->getArgument('migration-id');
		$output->writeln('<info>Running migration ' . $id . '</info>');
		$this->migrationService->runMigration($id);
		$output->writeln('<info>Done</info>');
		return Command::SUCCESS;
	}
}
