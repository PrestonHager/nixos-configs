document.getElementById('cloudmigrate-admin-form').addEventListener('submit', function (e) {
	e.preventDefault();
	const form = e.target;
	const data = {
		onedrive_client_id: form.onedrive_client_id.value,
		onedrive_client_secret: form.onedrive_client_secret.value,
		onedrive_tenant: form.onedrive_tenant.value,
	};
	const status = document.getElementById('cloudmigrate-admin-status');
	fetch(OC.generateUrl('/apps/cloudmigrate/settings/admin'), {
		method: 'POST',
		credentials: 'same-origin',
		headers: {
			'Content-Type': 'application/json',
			requesttoken: OC.requestToken,
		},
		body: JSON.stringify(data),
	})
		.then((r) => r.json())
		.then(() => {
			status.textContent = t('cloudmigrate', 'Saved');
			form.onedrive_client_secret.value = '';
		})
		.catch(() => {
			status.textContent = t('cloudmigrate', 'Save failed');
		});
});
