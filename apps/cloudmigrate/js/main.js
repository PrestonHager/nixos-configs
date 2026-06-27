(function () {
	const appRoot = document.getElementById('cloudmigrate-app');
	if (!appRoot) return;

	const flash = appRoot.dataset.flash;
	const flashEl = document.getElementById('cloudmigrate-flash');
	if (flash) {
		flashEl.textContent = flash;
		flashEl.hidden = false;
	}

	const api = (path, options = {}) => {
		const headers = Object.assign({ requesttoken: OC.requestToken }, options.headers || {});
		if (options.body && typeof options.body === 'object' && !(options.body instanceof FormData)) {
			headers['Content-Type'] = 'application/json';
			options.body = JSON.stringify(options.body);
		}
		return fetch(OC.generateUrl('/apps/cloudmigrate' + path), Object.assign({ credentials: 'same-origin' }, options, { headers }))
			.then((r) => r.json().then((j) => ({ ok: r.ok, status: r.status, json: j })));
	};

	const onedriveConnect = document.getElementById('onedrive-connect');
	const onedriveDisconnect = document.getElementById('onedrive-disconnect');
	const onedriveMigrate = document.getElementById('onedrive-migrate');
	const onedriveFolder = document.getElementById('onedrive-folder');
	const onedriveStart = document.getElementById('onedrive-start');
	const onedriveAdminHint = document.getElementById('onedrive-admin-hint');
	const migrationList = document.getElementById('migration-list');

	function renderMigrations(migrations) {
		if (!migrations.length) {
			migrationList.innerHTML = '<em>' + t('cloudmigrate', 'No migrations yet.') + '</em>';
			return;
		}
		migrationList.innerHTML = migrations.map((m) => {
			const label = m.dryRun ? ' (dry run)' : '';
			return '<div class="migration-row">' +
				'<strong>' + escapeHtml(m.provider) + '</strong> ' + escapeHtml(m.sourcePath) + ' → ' + escapeHtml(m.destPath) + label +
				'<br><span class="status-' + escapeHtml(m.status) + '">' + escapeHtml(m.status) + '</span> ' +
				m.progress + '% (' + m.copiedFiles + '/' + m.totalFiles + ')' +
				(m.errorMessage ? '<br><span class="error">' + escapeHtml(m.errorMessage) + '</span>' : '') +
				'</div>';
		}).join('');
	}

	function escapeHtml(s) {
		const d = document.createElement('div');
		d.textContent = s || '';
		return d.innerHTML;
	}

	function refreshStatus() {
		return api('/api/status').then(({ ok, json }) => {
			if (!ok) return;
			const od = json.onedrive;
			if (!od.adminConfigured) {
				onedriveAdminHint.textContent = t('cloudmigrate', 'Ask an administrator to configure the Azure app (Settings → Administration → Cloud Migrate).');
				onedriveConnect.hidden = true;
			} else {
				onedriveAdminHint.textContent = '';
				onedriveConnect.hidden = od.connected;
			}
			onedriveDisconnect.hidden = !od.connected;
			onedriveMigrate.hidden = !od.connected;
			if (od.connected) {
				loadFolders();
			}
			const ic = json.icloud;
			document.getElementById('icloud-disconnect').hidden = !ic.configured;
			renderMigrations(json.migrations || []);
		});
	}

	function loadFolders() {
		api('/api/onedrive/folders').then(({ ok, json }) => {
			if (!ok) return;
			onedriveFolder.innerHTML = (json.folders || []).map((f) =>
				'<option value="' + escapeHtml(f.id) + '" data-label="' + escapeHtml(f.name) + '">' + escapeHtml(f.name) + '</option>'
			).join('');
		});
	}

	onedriveDisconnect.addEventListener('click', () => {
		api('/api/disconnect/onedrive', { method: 'POST' }).then(refreshStatus);
	});

	onedriveStart.addEventListener('click', () => {
		const opt = onedriveFolder.selectedOptions[0];
		if (!opt) return;
		const dryRun = document.getElementById('onedrive-dryrun').checked;
		const destSubpath = document.getElementById('onedrive-dest').value || 'Files';
		onedriveStart.disabled = true;
		api('/api/migrate', {
			method: 'POST',
			body: {
				provider: 'onedrive',
				folderId: opt.value,
				sourceLabel: opt.dataset.label || opt.textContent,
				destSubpath,
				dryRun,
			},
		}).then(() => {
			onedriveStart.disabled = false;
			refreshStatus();
			setInterval(refreshStatus, 5000);
		});
	});

	document.getElementById('icloud-save').addEventListener('click', () => {
		api('/api/icloud/credentials', {
			method: 'POST',
			body: {
				appleId: document.getElementById('icloud-apple-id').value,
				appPassword: document.getElementById('icloud-password').value,
			},
		}).then(({ json }) => {
			alert(json.message || 'Saved');
			refreshStatus();
		});
	});

	document.getElementById('icloud-disconnect').addEventListener('click', () => {
		api('/api/disconnect/icloud', { method: 'POST' }).then(refreshStatus);
	});

	refreshStatus();
	setInterval(refreshStatus, 15000);
})();
