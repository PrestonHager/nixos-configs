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

	<label><?php p($l->t('Redirect URI (add in Azure)')); ?></label>
	<input type="text" readonly value="<?php p($_['redirectUri']); ?>" onclick="this.select();" />

	<p class="hint">
		<?php p($l->t('API permissions (delegated): Files.Read, User.Read, offline_access')); ?>
	</p>

	<button type="submit" class="button primary"><?php p($l->t('Save')); ?></button>
	<span id="cloudmigrate-admin-status"></span>
</form>
