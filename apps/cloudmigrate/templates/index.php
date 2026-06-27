<?php
/** @var array $_ */
/** @var \OCP\IL10N $l */
script('cloudmigrate', 'main');
style('cloudmigrate', 'main');
?>
<div id="cloudmigrate-app" class="section" data-flash="<?php p($_['flash'] ?? '') ?>">
	<h2><?php p($l->t('Cloud Migrate')); ?></h2>
	<p class="cloudmigrate-lead">
		<?php p($l->t('Copy files from Microsoft OneDrive or Apple iCloud into your Nextcloud files under Migrated/. This is a one-time migration tool, not ongoing sync.')); ?>
	</p>

	<div id="cloudmigrate-flash" class="cloudmigrate-flash" hidden></div>

	<section class="cloudmigrate-card" id="onedrive-section">
		<h3><?php p($l->t('Microsoft OneDrive')); ?></h3>
		<p id="onedrive-admin-hint" class="hint"></p>
		<div class="cloudmigrate-actions">
			<a id="onedrive-connect" class="button primary" href="<?php p(\OC::$server->getURLGenerator()->linkToRoute('cloudmigrate.oauth.onedrive')); ?>">
				<?php p($l->t('Connect OneDrive')); ?>
			</a>
			<button id="onedrive-disconnect" class="button" type="button" hidden><?php p($l->t('Disconnect')); ?></button>
		</div>

		<div id="onedrive-migrate" hidden>
			<label for="onedrive-folder"><?php p($l->t('Source folder')); ?></label>
			<select id="onedrive-folder"></select>

			<label for="onedrive-dest"><?php p($l->t('Destination under Migrated/OneDrive/')); ?></label>
			<input id="onedrive-dest" type="text" value="Files" />

			<label class="cloudmigrate-checkbox">
				<input id="onedrive-dryrun" type="checkbox" />
				<?php p($l->t('Dry run (count files only, no copy)')); ?>
			</label>

			<button id="onedrive-start" class="button primary" type="button"><?php p($l->t('Start migration')); ?></button>
		</div>
	</section>

	<section class="cloudmigrate-card cloudmigrate-card-muted" id="icloud-section">
		<h3><?php p($l->t('Apple iCloud')); ?></h3>
		<p class="hint">
			<?php p($l->t('Apple does not offer a public web OAuth API for iCloud Drive comparable to Microsoft Graph. Phase 2 supports storing an app-specific password (encrypted in Nextcloud) as a fallback; Drive and Photos copy jobs are not yet implemented.')); ?>
		</p>
		<details>
			<summary><?php p($l->t('App-specific password (optional, Phase 2 scaffold)')); ?></summary>
			<p class="hint">
				<?php p($l->t('Generate at appleid.apple.com → Sign-In and Security → App-Specific Passwords. Stored encrypted per user in this app — never in git or sops.')); ?>
			</p>
			<label for="icloud-apple-id"><?php p($l->t('Apple ID')); ?></label>
			<input id="icloud-apple-id" type="email" autocomplete="username" />
			<label for="icloud-password"><?php p($l->t('App-specific password')); ?></label>
			<input id="icloud-password" type="password" autocomplete="current-password" />
			<button id="icloud-save" class="button" type="button"><?php p($l->t('Save credentials')); ?></button>
			<button id="icloud-disconnect" class="button" type="button" hidden><?php p($l->t('Remove credentials')); ?></button>
		</details>
		<p class="cloudmigrate-badge"><?php p($l->t('Coming soon: Drive via server-side rclone, Photos via icloudpd background job')); ?></p>
	</section>

	<section class="cloudmigrate-card">
		<h3><?php p($l->t('Migration status')); ?></h3>
		<div id="migration-list"><em><?php p($l->t('Loading…')); ?></em></div>
	</section>
</div>
