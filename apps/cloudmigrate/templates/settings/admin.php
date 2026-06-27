<?php
/** @var array $_ */
/** @var \OCP\IL10N $l */
?>
<form id="cloudmigrate-admin-form" class="section">
	<h2><?php p($l->t('Cloud Migrate — Microsoft OneDrive')); ?></h2>
	<p>
		<?php p($l->t('Register an Azure AD app and enter the Client ID here. Users connect their own OneDrive accounts via OAuth; refresh tokens are stored encrypted per user.')); ?>
	</p>
	<p>
		<a href="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade" target="_blank" rel="noopener noreferrer">
			<?php p($l->t('Azure Portal → App registrations')); ?>
		</a>
	</p>

	<label for="onedrive_client_id"><?php p($l->t('Application (client) ID')); ?></label>
	<input id="onedrive_client_id" name="onedrive_client_id" type="text" value="<?php p($_['clientId']); ?>" required />

	<label for="onedrive_client_secret"><?php p($l->t('Client secret (optional for public/mobile clients)')); ?></label>
	<input id="onedrive_client_secret" name="onedrive_client_secret" type="password" placeholder="<?php p($_['hasSecret'] ? '••••••••' : ''); ?>" autocomplete="new-password" />

	<label for="onedrive_tenant"><?php p($l->t('Tenant')); ?></label>
	<input id="onedrive_tenant" name="onedrive_tenant" type="text" value="<?php p($_['tenant']); ?>" placeholder="common" />
	<p class="hint"><?php p($l->t('Use "common" for personal and work/school Microsoft accounts.')); ?></p>

	<label><?php p($l->t('Redirect URI (register in Azure)')); ?></label>
	<input type="text" readonly value="<?php p($_['redirectUri']); ?>" onclick="this.select();" />
	<p class="hint">
		<?php p($l->t('Add this exact URI under Azure → App registration → Authentication → Web → Redirect URIs. Microsoft requires an exact match (scheme, host, path — no trailing slash).')); ?>
	</p>
	<?php if (!empty($_['redirectUriCandidates']) && count($_['redirectUriCandidates']) > 1): ?>
	<label><?php p($l->t('Also register (if Connect still fails)')); ?></label>
	<input type="text" readonly value="<?php p($_['redirectUriCandidates'][1]); ?>" onclick="this.select();" />
	<p class="hint"><?php p($l->t('Some Nextcloud setups use index.php in app URLs; register both URIs in Azure if unsure.')); ?></p>
	<?php endif; ?>

	<label for="onedrive_redirect_uri_base"><?php p($l->t('Redirect URI base override (optional)')); ?></label>
	<input id="onedrive_redirect_uri_base" name="onedrive_redirect_uri_base" type="url" value="<?php p($_['redirectUriBase']); ?>" placeholder="https://cloud.prestonhager.com" />
	<p class="hint"><?php p($l->t('Leave empty to auto-detect from Nextcloud. Set only if auto-detect is wrong (reverse proxy, custom domain).')); ?></p>
	<p class="hint">
		<?php p($l->t('API permissions (delegated): Files.Read, User.Read, offline_access')); ?>
	</p>

	<button type="submit" class="button primary"><?php p($l->t('Save')); ?></button>
	<span id="cloudmigrate-admin-status"></span>
</form>
