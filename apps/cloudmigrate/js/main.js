(function () {
	const appRoot = document.getElementById('cloudmigrate-app');
	if (!appRoot) return;

	const flashEl = document.getElementById('cloudmigrate-flash');
	const onedriveConnect = document.getElementById('onedrive-connect');
	const onedriveDisconnect = document.getElementById('onedrive-disconnect');
	const onedriveMigrate = document.getElementById('onedrive-migrate');
	const onedriveFolder = document.getElementById('onedrive-folder');
	const onedriveStart = document.getElementById('onedrive-start');
	const onedriveAdminHint = document.getElementById('onedrive-admin-hint');
	const onedriveActionFeedback = document.getElementById('onedrive-action-feedback');
	const migrationList = document.getElementById('migration-list');
	const migrationStatusSection = document.getElementById('migration-status-section');

	let pollTimer = null;
	let lastActiveMigrationCount = 0;

	const flash = appRoot.dataset.flash;
	if (flash) {
		showFlash(flash, 'success');
	}

	const api = (path, options = {}) => {
		const headers = Object.assign({ requesttoken: OC.requestToken }, options.headers || {});
		if (options.body && typeof options.body === 'object' && !(options.body instanceof FormData)) {
			headers['Content-Type'] = 'application/json';
			options.body = JSON.stringify(options.body);
		}
		return fetch(OC.generateUrl('/apps/cloudmigrate' + path), Object.assign({ credentials: 'same-origin' }, options, { headers }))
			.then((r) => r.json().then((j) => ({ ok: r.ok, status: r.status, json: j })))
			.catch(() => ({ ok: false, status: 0, json: { message: t('cloudmigrate', 'Network error — please try again.') } }));
	};

	function showFlash(message, type) {
		flashEl.textContent = message;
		flashEl.hidden = false;
		flashEl.className = 'cloudmigrate-flash' + (type ? ' cloudmigrate-flash-' + type : '');
	}

	function notify(message, type) {
		if (typeof OC !== 'undefined' && OC.Notification && OC.Notification.showTemporary) {
			OC.Notification.showTemporary(message, type === 'error' ? { type: 'error' } : undefined);
		}
	}

	function setInlineFeedback(el, message, type) {
		if (!el) return;
		if (!message) {
			el.hidden = true;
			el.textContent = '';
			el.className = 'cloudmigrate-inline-feedback';
			return;
		}
		el.hidden = false;
		el.textContent = message;
		el.className = 'cloudmigrate-inline-feedback is-' + type;
	}

	function setButtonLoading(btn, loading, loadingLabel) {
		if (!btn) return;
		if (loading) {
			if (!btn.dataset.originalText) {
				btn.dataset.originalText = btn.textContent;
			}
			btn.disabled = true;
			btn.classList.add('icon-loading');
			if (loadingLabel) {
				btn.textContent = loadingLabel;
			}
		} else {
			btn.disabled = false;
			btn.classList.remove('icon-loading');
			if (btn.dataset.originalText) {
				btn.textContent = btn.dataset.originalText;
			}
		}
	}

	function formatMigrationSummary(m) {
		if (m.dryRun && m.status === 'completed') {
			return t('cloudmigrate', 'Dry run complete: {count} file(s) found in {source}.', {
				count: m.totalFiles,
				source: m.sourcePath,
			});
		}
		if (m.dryRun && m.status === 'running') {
			return t('cloudmigrate', 'Dry run in progress… {done}/{total} files scanned.', {
				done: m.copiedFiles,
				total: m.totalFiles || '?',
			});
		}
		if (!m.dryRun && m.status === 'completed') {
			return t('cloudmigrate', 'Migration complete: {copied}/{total} file(s) copied to {dest}.', {
				copied: m.copiedFiles,
				total: m.totalFiles,
				dest: m.destPath,
			});
		}
		return '';
	}

	function renderMigrations(migrations) {
		if (!migrations.length) {
			migrationList.innerHTML = '<em>' + t('cloudmigrate', 'No migrations yet.') + '</em>';
			return;
		}
		migrationList.innerHTML = migrations.map((m) => {
			const label = m.dryRun ? ' (' + t('cloudmigrate', 'dry run') + ')' : '';
			const summary = formatMigrationSummary(m);
			return '<div class="migration-row">' +
				'<strong>' + escapeHtml(m.provider) + '</strong> ' + escapeHtml(m.sourcePath) + ' → ' + escapeHtml(m.destPath) + label +
				'<br><span class="status-' + escapeHtml(m.status) + '">' + escapeHtml(m.status) + '</span> ' +
				m.progress + '% (' + m.copiedFiles + '/' + m.totalFiles + ')' +
				(summary ? '<br><span class="hint">' + escapeHtml(summary) + '</span>' : '') +
				(m.errorMessage ? '<br><span class="error">' + escapeHtml(m.errorMessage) + '</span>' : '') +
				'</div>';
		}).join('');
	}

	function escapeHtml(s) {
		const d = document.createElement('div');
		d.textContent = s || '';
		return d.innerHTML;
	}

	function hasActiveMigrations(migrations) {
		return migrations.some((m) => m.status === 'queued' || m.status === 'running');
	}

	function configurePolling(migrations) {
		const active = hasActiveMigrations(migrations);
		const interval = active ? 3000 : 15000;
		if (pollTimer) {
			clearInterval(pollTimer);
		}
		pollTimer = setInterval(refreshStatus, interval);

		if (lastActiveMigrationCount > 0 && !active) {
			const latest = migrations[0];
			if (latest) {
				const summary = formatMigrationSummary(latest);
				if (summary) {
					notify(summary, latest.status === 'failed' ? 'error' : undefined);
					showFlash(summary, latest.status === 'failed' ? 'error' : 'success');
				}
			}
		}
		lastActiveMigrationCount = active ? migrations.filter((m) => m.status === 'queued' || m.status === 'running').length : 0;
	}

	function refreshStatus() {
		return api('/api/status').then(({ ok, json }) => {
			if (!ok) {
				migrationList.innerHTML = '<span class="error">' + escapeHtml(json.message || t('cloudmigrate', 'Could not load status.')) + '</span>';
				return;
			}
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
			const migrations = json.migrations || [];
			renderMigrations(migrations);
			configurePolling(migrations);
		});
	}

	function loadFolders() {
		api('/api/onedrive/folders').then(({ ok, json }) => {
			if (!ok) {
				setInlineFeedback(onedriveActionFeedback, json.message || t('cloudmigrate', 'Could not load OneDrive folders.'), 'error');
				return;
			}
			onedriveFolder.innerHTML = (json.folders || []).map((f) =>
				'<option value="' + escapeHtml(f.id) + '" data-label="' + escapeHtml(f.name) + '">' + escapeHtml(f.name) + '</option>'
			).join('');
		});
	}

	onedriveDisconnect.addEventListener('click', () => {
		api('/api/disconnect/onedrive', { method: 'POST' }).then(({ ok, json }) => {
			if (!ok) {
				notify(json.message || t('cloudmigrate', 'Disconnect failed.'), 'error');
				return;
			}
			refreshStatus();
		});
	});

	onedriveStart.addEventListener('click', () => {
		const opt = onedriveFolder.selectedOptions[0];
		if (!opt) {
			const msg = t('cloudmigrate', 'Select a source folder first.');
			setInlineFeedback(onedriveActionFeedback, msg, 'error');
			notify(msg, 'error');
			return;
		}
		const dryRun = document.getElementById('onedrive-dryrun').checked;
		const destSubpath = document.getElementById('onedrive-dest').value || 'Files';
		const loadingLabel = dryRun
			? t('cloudmigrate', 'Starting dry run…')
			: t('cloudmigrate', 'Starting migration…');

		setButtonLoading(onedriveStart, true, loadingLabel);
		setInlineFeedback(onedriveActionFeedback, loadingLabel, 'loading');

		api('/api/migrate', {
			method: 'POST',
			body: {
				provider: 'onedrive',
				folderId: opt.value,
				sourceLabel: opt.dataset.label || opt.textContent,
				destSubpath,
				dryRun,
			},
		}).then(({ ok, json }) => {
			setButtonLoading(onedriveStart, false);

			if (!ok) {
				const msg = json.message || t('cloudmigrate', 'Migration failed to start.');
				setInlineFeedback(onedriveActionFeedback, msg, 'error');
				showFlash(msg, 'error');
				notify(msg, 'error');
				return;
			}

			const m = json.migration || {};
			const msg = dryRun
				? t('cloudmigrate', 'Dry run queued for "{source}". Results will appear in Migration status below.', { source: m.sourcePath || opt.textContent })
				: t('cloudmigrate', 'Migration queued for "{source}" → {dest}. Progress appears below.', {
					source: m.sourcePath || opt.textContent,
					dest: m.destPath || destSubpath,
				});

			setInlineFeedback(onedriveActionFeedback, msg, 'success');
			showFlash(msg, 'success');
			notify(msg);

			refreshStatus().then(() => {
				if (migrationStatusSection) {
					migrationStatusSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
				}
			});
		});
	});

	document.getElementById('icloud-save').addEventListener('click', () => {
		api('/api/icloud/credentials', {
			method: 'POST',
			body: {
				appleId: document.getElementById('icloud-apple-id').value,
				appPassword: document.getElementById('icloud-password').value,
			},
		}).then(({ ok, json }) => {
			const msg = json.message || (ok ? t('cloudmigrate', 'Saved') : t('cloudmigrate', 'Save failed.'));
			if (ok) {
				showFlash(msg, 'success');
				notify(msg);
			} else {
				showFlash(msg, 'error');
				notify(msg, 'error');
			}
			refreshStatus();
		});
	});

	document.getElementById('icloud-disconnect').addEventListener('click', () => {
		api('/api/disconnect/icloud', { method: 'POST' }).then(refreshStatus);
	});

	refreshStatus();
})();
