<?php
/** @var array $_ */
/** @var \OCP\IL10N $l */
?>
<div id="app-content">
	<div id="cloudmigrate-app" data-flash="<?php p($_['flash'] ?? '') ?>">
		<h2><?php p($l->t('Cloud Migrate')); ?></h2>
		<p class="cloudmigrate-lead">
			<?php p($l->t('Copy files from Microsoft OneDrive or Apple iCloud into your Nextcloud files under Migrated/. This is a one-time migration tool, not ongoing sync.')); ?>
		</p>

		<div id="cloudmigrate-flash" class="cloudmigrate-flash" hidden></div>

		<section class="cloudmigrate-card" id="onedrive-section">
			<h3><?php p($l->t('Microsoft OneDrive')); ?></h3>
			<p id="onedrive-admin-hint" class="hint"></p>
			<div class="cloudmigrate-actions">
				<a id="onedrive-connect" class="button primary" href="<?php p($_['onedriveConnectUrl'] ?? ''); ?>">
					<?php p($l->t('Connect OneDrive')); ?>
				</a>
				<button id="onedrive-disconnect" class="button" type="button" hidden><?php p($l->t('Disconnect')); ?></button>
			</div>

			<div id="onedrive-migrate" hidden>
				<label><?php p($l->t('Source folder')); ?></label>
				<div id="onedrive-browser" class="cloudmigrate-browser">
					<nav id="onedrive-breadcrumb" class="cloudmigrate-breadcrumb" aria-label="<?php p($l->t('OneDrive folder path')); ?>"></nav>
					<div id="onedrive-folder-list" class="cloudmigrate-folder-list"></div>
					<p id="onedrive-selected" class="hint"></p>
				</div>
				<label for="onedrive-path"><?php p($l->t('Or enter OneDrive path')); ?></label>
				<div class="cloudmigrate-path-row">
					<input id="onedrive-path" type="text" placeholder="<?php p($l->t('e.g. Documents/Reports')); ?>" />
					<button id="onedrive-path-go" class="button" type="button"><?php p($l->t('Go')); ?></button>
				</div>

				<label for="onedrive-dest-base"><?php p($l->t('Destination base path in Nextcloud Files')); ?></label>
				<input id="onedrive-dest-base" type="text" value="Migrated/OneDrive" />

				<label for="onedrive-dest-sub"><?php p($l->t('Destination subfolder (optional)')); ?></label>
				<input id="onedrive-dest-sub" type="text" placeholder="<?php p($l->t('e.g. Documents — leave empty to mirror source name')); ?>" />

				<label class="cloudmigrate-checkbox">
					<input id="onedrive-dryrun" type="checkbox" />
					<?php p($l->t('Dry run (count files only, no copy)')); ?>
				</label>

				<div class="cloudmigrate-actions">
					<button id="onedrive-start" class="button primary" type="button"><?php p($l->t('Start migration')); ?></button>
				</div>
				<p id="onedrive-action-feedback" class="cloudmigrate-inline-feedback" hidden aria-live="polite"></p>
			</div>
		</section>

		<section class="cloudmigrate-card" id="icloud-section">
			<h3><?php p($l->t('Apple iCloud')); ?></h3>
			<p class="hint">
				<?php p($l->t('iCloud Drive uses rclone with your Apple ID password and a one-time two-factor sign-in. Trust tokens last about 30 days; then sign in again. App-specific passwords are not supported by rclone 1.74.')); ?>
			</p>
			<p id="icloud-rclone-hint" class="hint error" hidden></p>

			<div id="icloud-connect">
				<label for="icloud-apple-id"><?php p($l->t('Apple ID')); ?></label>
				<input id="icloud-apple-id" type="email" autocomplete="username" />
				<label for="icloud-password"><?php p($l->t('Apple ID password')); ?></label>
				<input id="icloud-password" type="password" autocomplete="current-password" />
				<div class="cloudmigrate-actions">
					<button id="icloud-save" class="button primary" type="button"><?php p($l->t('Save credentials')); ?></button>
				</div>
			</div>

			<div id="icloud-connected" hidden>
				<div id="icloud-auth-panel">
					<div id="icloud-auth-step-start">
						<p class="hint"><?php p($l->t('Step 1: Start sign-in. Apple will send a verification code to a trusted device or phone.')); ?></p>
						<div class="cloudmigrate-actions">
							<button id="icloud-auth-start" class="button primary" type="button"><?php p($l->t('Start sign-in')); ?></button>
						</div>
					</div>
					<div id="icloud-auth-step-2fa" hidden>
						<p id="icloud-auth-message" class="hint cloudmigrate-auth-waiting"><?php p($l->t('Step 2: Enter the verification code and click Submit code. Do not click Start sign-in again — that sends a new code.')); ?></p>
						<label for="icloud-2fa-code"><?php p($l->t('Verification code')); ?></label>
						<input id="icloud-2fa-code" type="text" inputmode="numeric" autocomplete="one-time-code" placeholder="<?php p($l->t('6-digit code, or type sms')); ?>" />
						<div class="cloudmigrate-actions">
							<button id="icloud-auth-submit" class="button primary" type="button"><?php p($l->t('Submit code')); ?></button>
							<button id="icloud-auth-restart" class="button" type="button"><?php p($l->t('Restart sign-in')); ?></button>
						</div>
					</div>
				</div>
				<p id="icloud-auth-status" class="cloudmigrate-badge" hidden></p>
				<div class="cloudmigrate-actions">
					<button id="icloud-disconnect" class="button" type="button"><?php p($l->t('Remove credentials')); ?></button>
				</div>

				<div id="icloud-migrate" hidden>
					<label for="icloud-folder"><?php p($l->t('Source folder')); ?></label>
					<select id="icloud-folder">
						<option value="" data-label="<?php p($l->t('All iCloud Drive files')); ?>"><?php p($l->t('All iCloud Drive files')); ?></option>
					</select>

					<label for="icloud-source-path"><?php p($l->t('Or enter source path (optional)')); ?></label>
					<input id="icloud-source-path" type="text" placeholder="<?php p($l->t('e.g. Documents/Archive')); ?>" />

					<label for="icloud-dest"><?php p($l->t('Destination path in Nextcloud Files')); ?></label>
					<input id="icloud-dest" type="text" value="Migrated/iCloud" />

					<label class="cloudmigrate-checkbox">
						<input id="icloud-dryrun" type="checkbox" />
						<?php p($l->t('Dry run (count files only, no copy)')); ?>
					</label>

					<div class="cloudmigrate-actions">
						<button id="icloud-start" class="button primary" type="button"><?php p($l->t('Start migration')); ?></button>
					</div>
					<p id="icloud-action-feedback" class="cloudmigrate-inline-feedback" hidden aria-live="polite"></p>
				</div>
			</div>
			<p class="cloudmigrate-badge"><?php p($l->t('iCloud Photos via icloudpd — coming soon')); ?></p>
		</section>

		<section class="cloudmigrate-card" id="migration-status-section">
			<h3><?php p($l->t('Migration status')); ?></h3>
			<div id="migration-list"><em><?php p($l->t('Loading…')); ?></em></div>
		</section>
	</div>
</div>
