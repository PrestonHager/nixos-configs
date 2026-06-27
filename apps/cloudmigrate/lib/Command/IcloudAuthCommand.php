<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Command;

use OCA\CloudMigrate\Service\ICloudService;
use OCA\CloudMigrate\Service\RcloneAuthService;
use OCA\CloudMigrate\Service\TokenStore;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Question\Question;

class IcloudAuthCommand extends Command {
	public function __construct(
		private TokenStore $tokenStore,
		private ICloudService $iCloudService,
	) {
		parent::__construct();
	}

	protected function configure(): void {
		$this
			->setName('cloudmigrate:icloud-auth')
			->setDescription('Complete iCloud Drive sign-in (Apple ID password + 2FA) for a Nextcloud user')
			->addArgument('user-id', InputArgument::REQUIRED, 'Nextcloud user ID (uid)');
	}

	protected function execute(InputInterface $input, OutputInterface $output): int {
		$userId = (string)$input->getArgument('user-id');
		if (!$this->tokenStore->isIcloudConfigured($userId)) {
			$output->writeln('<error>User has not saved Apple ID credentials in Cloud Migrate.</error>');
			$output->writeln('Open Cloud Migrate in the browser, enter Apple ID + password, then re-run this command.');
			return Command::FAILURE;
		}

		$output->writeln('<info>Starting iCloud sign-in for ' . $userId . '…</info>');
		$output->writeln('<comment>Use your regular Apple ID password (not an app-specific password).</comment>');

		try {
			$result = $this->iCloudService->startAuth($userId);
		} catch (\Throwable $e) {
			$output->writeln('<error>' . $e->getMessage() . '</error>');
			return Command::FAILURE;
		}

		while (($result['status'] ?? '') === RcloneAuthService::STATUS_NEEDS_2FA) {
			$output->writeln('<info>' . ($result['message'] ?? 'Enter 2FA code') . '</info>');
			$helper = $this->getHelper('question');
			$question = new Question('2FA code (or sms): ');
			$code = trim((string)$helper->ask($input, $output, $question));
			if ($code === '') {
				$output->writeln('<error>Code required.</error>');
				return Command::FAILURE;
			}
			try {
				$result = $this->iCloudService->continueAuth($userId, (string)($result['state'] ?? '2fa_do'), $code);
			} catch (\Throwable $e) {
				$output->writeln('<error>' . $e->getMessage() . '</error>');
				return Command::FAILURE;
			}
		}

		if (($result['status'] ?? '') === RcloneAuthService::STATUS_AUTHENTICATED) {
			$output->writeln('<info>' . ($result['message'] ?? 'Authenticated.') . '</info>');
			return Command::SUCCESS;
		}

		$output->writeln('<error>Unexpected status: ' . ($result['status'] ?? 'unknown') . '</error>');
		return Command::FAILURE;
	}
}
