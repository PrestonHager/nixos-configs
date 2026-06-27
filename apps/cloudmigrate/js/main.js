(function () {
	const appRoot = document.getElementById('cloudmigrate-app');
	if (!appRoot) return;

	const flashEl = document.getElementById('cloudmigrate-flash');
	const onedriveConnect = document.getElementById('onedrive-connect');
	const onedriveDisconnect = document.getElementById('onedrive-disconnect');
	const onedriveMigrate = document.getElementById('onedrive-migrate');
	const onedriveStart = document.getElementById('onedrive-start');
	const onedriveAdminHint = document.getElementById('onedrive-admin-hint');
	const onedriveActionFeedback = document.getElementById('onedrive-action-feedback');
	const onedriveBreadcrumb = document.getElementById('onedrive-breadcrumb');
	const onedriveFolderList = document.getElementById('onedrive-folder-list');
	const onedriveSelected = document.getElementById('onedrive-selected');
	const onedrivePath = document.getElementById('onedrive-path');
	const onedrivePathGo = document.getElementById('onedrive-path-go');
	const migrationList = document.getElementById('migration-list');
	const migrationStatusSection = document.getElementById('migration-status-section');
	const icloudConnect = document.getElementById('icloud-connect');
	const icloudConnected = document.getElementById('icloud-connected');
	const icloudFolder = document.getElementById('icloud-folder');
	const icloudStart = document.getElementById('icloud-start');
	const icloudRcloneHint = document.getElementById('icloud-rclone-hint');
	const icloudActionFeedback = document.getElementById('icloud-action-feedback');
	const icloudAuthPanel = document.getElementById('icloud-auth-panel');
	const icloudAuthMessage = document.getElementById('icloud-auth-message');
	const icloudAuthStatus = document.getElementById('icloud-auth-status');
	const icloudMigrate = document.getElementById('icloud-migrate');
	const icloudAuthStart = document.getElementById('icloud-auth-start');
	const icloudAuthSubmit = document.getElementById('icloud-auth-submit');
	const icloud2faCode = document.getElementById('icloud-2fa-code');

	let pollTimer = null;
	let lastActiveMigrationCount = 0;
	let onedriveConnected = false;
	let foldersLoaded = false;
	let icloudFoldersLoaded = false;
	let icloudAuthState = '';
	let selectedFolder = { id: 'root', path: 'OneDrive', label: 'OneDrive' };

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

	function updateSelectedDisplay() {
		const fileHint = selectedFolder.fileCount != null
			? t('cloudmigrate', '{count} file(s) in this folder (subfolders scanned during migration).', { count: selectedFolder.fileCount })
			: '';
		onedriveSelected.textContent = t('cloudmigrate', 'Selected: {path}', { path: selectedFolder.label }) +
			(fileHint ? ' — ' + fileHint : '');
	}

	function renderBreadcrumb(breadcrumb) {
		if (!breadcrumb || !breadcrumb.length) {
			onedriveBreadcrumb.innerHTML = '';
			return;
		}
		onedriveBreadcrumb.innerHTML = breadcrumb.map((crumb, idx) => {
			const sep = idx > 0 ? '<span class="cloudmigrate-breadcrumb-sep">›</span>' : '';
			return sep + '<button type="button" class="cloudmigrate-breadcrumb-item" data-folder-id="' +
				escapeHtml(crumb.id) + '">' + escapeHtml(crumb.name) + '</button>';
		}).join('');
		onedriveBreadcrumb.querySelectorAll('.cloudmigrate-breadcrumb-item').forEach((btn) => {
			btn.addEventListener('click', () => browseFolder(btn.dataset.folderId));
		});
	}

	function renderFolderList(data) {
		const folders = data.folders || [];
		if (!folders.length) {
			onedriveFolderList.innerHTML = '<p class="hint">' + t('cloudmigrate', 'No subfolders here.') + '</p>';
			return;
		}
		onedriveFolderList.innerHTML = folders.map((f) =>
			'<button type="button" class="cloudmigrate-folder-item" data-folder-id="' + escapeHtml(f.id) + '" data-folder-path="' + escapeHtml(f.path || f.name) + '">' +
			'<span class="icon-folder"></span> ' + escapeHtml(f.name) +
			'</button>'
		).join('');
		onedriveFolderList.querySelectorAll('.cloudmigrate-folder-item').forEach((btn) => {
			btn.addEventListener('click', () => browseFolder(btn.dataset.folderId));
		});
	}

	function browseFolder(folderId) {
		return api('/api/onedrive/browse?folderId=' + encodeURIComponent(folderId)).then(({ ok, json }) => {
			if (!ok) {
				setInlineFeedback(onedriveActionFeedback, json.message || t('cloudmigrate', 'Could not browse OneDrive.'), 'error');
				return;
			}
			renderBreadcrumb(json.breadcrumb);
			renderFolderList(json);
			selectedFolder = {
				id: json.folderId,
				path: json.folderPath || 'OneDrive',
				label: json.folderPath || 'OneDrive',
				fileCount: json.fileCount,
			};
			onedrivePath.value = json.folderPath || '';
			updateSelectedDisplay();
		});
	}

	function loadBrowser() {
		return browseFolder('root').then(() => {
			foldersLoaded = true;
		});
	}

	function loadIcloudFolders() {
		if (!icloudFolder) return Promise.resolve();
		return api('/api/icloud/folders').then(({ ok, json }) => {
			if (!ok) {
				setInlineFeedback(icloudActionFeedback, json.message || t('cloudmigrate', 'Could not load iCloud folders.'), 'error');
				return;
			}
			const allLabel = t('cloudmigrate', 'All iCloud Drive files');
			const options = ['<option value="" data-label="' + escapeHtml(allLabel) + '">' + escapeHtml(allLabel) + '</option>'];
			(json.folders || []).forEach((f) => {
				options.push(
					'<option value="' + escapeHtml(f.path) + '" data-label="' + escapeHtml(f.name) + '">' + escapeHtml(f.name) + '</option>'
				);
			});
			icloudFolder.innerHTML = options.join('');
			icloudFoldersLoaded = true;
		});
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
			if (od.connected && !onedriveConnected) {
				foldersLoaded = false;
			}
			if (od.connected && !foldersLoaded) {
				loadBrowser();
			}
			onedriveConnected = od.connected;
			const ic = json.icloud;
			icloudConnect.hidden = ic.configured;
			icloudConnected.hidden = !ic.configured;
			const authenticated = !!ic.authenticated;
			const authStatus = ic.authStatus || 'none';
			if (icloudAuthPanel) {
				icloudAuthPanel.hidden = authenticated;
			}
			if (icloudAuthStatus) {
				if (authenticated) {
					icloudAuthStatus.hidden = false;
					icloudAuthStatus.textContent = t('cloudmigrate', 'Signed in to iCloud Drive (trust token active). Re-sign before ~30 days if migrations fail.');
				} else if (ic.configured) {
					icloudAuthStatus.hidden = false;
					icloudAuthStatus.textContent = t('cloudmigrate', 'Credentials saved — complete Apple two-factor sign-in below.');
				} else {
					icloudAuthStatus.hidden = true;
				}
			}
			if (icloudMigrate) {
				icloudMigrate.hidden = !authenticated;
			}
			if (icloudAuthStart) {
				icloudAuthStart.hidden = authStatus === 'needs_2fa';
			}
			if (icloudAuthSubmit) {
				icloudAuthSubmit.hidden = authStatus !== 'needs_2fa';
			}
			if (ic.configured && ic.rcloneAvailable && authenticated) {
				icloudRcloneHint.hidden = true;
				icloudRcloneHint.textContent = '';
				if (!icloudFoldersLoaded) {
					loadIcloudFolders();
				}
			} else if (ic.configured && !ic.rcloneAvailable) {
				icloudRcloneHint.hidden = false;
				icloudRcloneHint.textContent = t('cloudmigrate', 'rclone is not installed in the Nextcloud container. Ask an administrator to deploy rclone (Settings → Administration → Cloud Migrate).');
			} else {
				icloudRcloneHint.hidden = true;
				icloudFoldersLoaded = false;
			}
			if (icloudStart) {
				icloudStart.disabled = !authenticated || !ic.rcloneAvailable;
			}
			const migrations = json.migrations || [];
			renderMigrations(migrations);
			configurePolling(migrations);
		});
	}

	onedriveDisconnect.addEventListener('click', () => {
		api('/api/disconnect/onedrive', { method: 'POST' }).then(({ ok, json }) => {
			if (!ok) {
				notify(json.message || t('cloudmigrate', 'Disconnect failed.'), 'error');
				return;
			}
			foldersLoaded = false;
			onedriveConnected = false;
			refreshStatus();
		});
	});

	onedrivePathGo.addEventListener('click', () => {
		const path = onedrivePath.value.trim();
		if (!path) {
			browseFolder('root');
			return;
		}
		setInlineFeedback(onedriveActionFeedback, t('cloudmigrate', 'Resolving path…'), 'loading');
		api('/api/onedrive/resolve-path?path=' + encodeURIComponent(path)).then(({ ok, json }) => {
			if (!ok) {
				setInlineFeedback(onedriveActionFeedback, json.message || t('cloudmigrate', 'Path not found.'), 'error');
				return;
			}
			setInlineFeedback(onedriveActionFeedback, '', '');
			browseFolder(json.folderId);
		});
	});

	onedriveStart.addEventListener('click', () => {
		if (!selectedFolder.id) {
			const msg = t('cloudmigrate', 'Select a source folder first.');
			setInlineFeedback(onedriveActionFeedback, msg, 'error');
			notify(msg, 'error');
			return;
		}
		const dryRun = document.getElementById('onedrive-dryrun').checked;
		const destBase = document.getElementById('onedrive-dest-base').value || 'Migrated/OneDrive';
		let destSubpath = document.getElementById('onedrive-dest-sub').value.trim();
		if (!destSubpath && selectedFolder.label && selectedFolder.label !== 'OneDrive') {
			destSubpath = selectedFolder.label.split('/').pop();
		}
		const loadingLabel = dryRun
			? t('cloudmigrate', 'Starting dry run…')
			: t('cloudmigrate', 'Starting migration…');

		setButtonLoading(onedriveStart, true, loadingLabel);
		setInlineFeedback(onedriveActionFeedback, loadingLabel, 'loading');

		api('/api/migrate', {
			method: 'POST',
			body: {
				provider: 'onedrive',
				folderId: selectedFolder.id,
				sourceLabel: selectedFolder.label,
				destBase,
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
				? t('cloudmigrate', 'Dry run queued for "{source}". Results will appear in Migration status below.', { source: m.sourcePath || selectedFolder.label })
				: t('cloudmigrate', 'Migration queued for "{source}" → {dest}. Progress appears below.', {
					source: m.sourcePath || selectedFolder.label,
					dest: m.destPath || destBase,
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
		const saveBtn = document.getElementById('icloud-save');
		const loadingLabel = t('cloudmigrate', 'Saving credentials…');
		setButtonLoading(saveBtn, true, loadingLabel);
		api('/api/icloud/credentials', {
			method: 'POST',
			body: {
				appleId: document.getElementById('icloud-apple-id').value,
				password: document.getElementById('icloud-password').value,
			},
		}).then(({ ok, json }) => {
			setButtonLoading(saveBtn, false);
			const msg = json.message || (ok ? t('cloudmigrate', 'Saved') : t('cloudmigrate', 'Save failed.'));
			if (ok) {
				showFlash(msg, 'success');
				notify(msg);
				document.getElementById('icloud-password').value = '';
				icloudAuthState = '';
				if (icloud2faCode) icloud2faCode.value = '';
			} else {
				showFlash(msg, 'error');
				notify(msg, 'error');
			}
			refreshStatus();
		});
	});

	function handleIcloudAuthResponse(json) {
		const msg = json.message || '';
		if (icloudAuthMessage && msg) {
			icloudAuthMessage.textContent = msg;
		}
		if (json.status === 'needs_2fa') {
			icloudAuthState = json.state || '2fa_do';
			if (icloudAuthStart) icloudAuthStart.hidden = true;
			if (icloudAuthSubmit) icloudAuthSubmit.hidden = false;
			showFlash(msg, 'success');
			notify(msg);
			if (icloud2faCode) icloud2faCode.focus();
		} else if (json.status === 'authenticated') {
			icloudAuthState = '';
			if (icloud2faCode) icloud2faCode.value = '';
			showFlash(msg, 'success');
			notify(msg);
			icloudFoldersLoaded = false;
		}
		refreshStatus();
	}

	if (icloudAuthStart) {
		icloudAuthStart.addEventListener('click', () => {
			setButtonLoading(icloudAuthStart, true, t('cloudmigrate', 'Contacting Apple…'));
			api('/api/icloud/auth/start', { method: 'POST' }).then(({ ok, json }) => {
				setButtonLoading(icloudAuthStart, false);
				if (!ok) {
					const err = json.message || t('cloudmigrate', 'Sign-in failed.');
					showFlash(err, 'error');
					notify(err, 'error');
					return;
				}
				handleIcloudAuthResponse(json);
			});
		});
	}

	if (icloudAuthSubmit) {
		icloudAuthSubmit.addEventListener('click', () => {
			const code = icloud2faCode ? icloud2faCode.value.trim() : '';
			if (!code) {
				showFlash(t('cloudmigrate', 'Enter the verification code.'), 'error');
				return;
			}
			setButtonLoading(icloudAuthSubmit, true, t('cloudmigrate', 'Verifying…'));
			api('/api/icloud/auth/continue', {
				method: 'POST',
				body: { state: icloudAuthState || '2fa_do', code },
			}).then(({ ok, json }) => {
				setButtonLoading(icloudAuthSubmit, false);
				if (!ok) {
					const err = json.message || t('cloudmigrate', 'Verification failed.');
					showFlash(err, 'error');
					notify(err, 'error');
					return;
				}
				handleIcloudAuthResponse(json);
			});
		});
	}

	document.getElementById('icloud-disconnect').addEventListener('click', () => {
		icloudAuthState = '';
		api('/api/disconnect/icloud', { method: 'POST' }).then(refreshStatus);
	});

	if (icloudStart) {
	icloudStart.addEventListener('click', () => {
		const manualPath = document.getElementById('icloud-source-path').value.trim();
		const opt = icloudFolder.selectedOptions[0];
		const sourcePath = manualPath !== '' ? manualPath : (opt ? opt.value : '');
		const sourceLabel = manualPath !== ''
			? manualPath
			: (opt && opt.dataset.label ? opt.dataset.label : t('cloudmigrate', 'All iCloud Drive files'));
		const dryRun = document.getElementById('icloud-dryrun').checked;
		const destPath = document.getElementById('icloud-dest').value || 'Migrated/iCloud';
		const loadingLabel = dryRun
			? t('cloudmigrate', 'Starting dry run…')
			: t('cloudmigrate', 'Starting migration…');

		setButtonLoading(icloudStart, true, loadingLabel);
		setInlineFeedback(icloudActionFeedback, loadingLabel, 'loading');

		api('/api/migrate', {
			method: 'POST',
			body: {
				provider: 'icloud',
				sourcePath,
				sourceLabel,
				destPath,
				dryRun,
			},
		}).then(({ ok, json }) => {
			setButtonLoading(icloudStart, false);

			if (!ok) {
				const msg = json.message || t('cloudmigrate', 'Migration failed to start.');
				setInlineFeedback(icloudActionFeedback, msg, 'error');
				showFlash(msg, 'error');
				notify(msg, 'error');
				return;
			}

			const m = json.migration || {};
			const msg = dryRun
				? t('cloudmigrate', 'Dry run queued for "{source}". Results will appear in Migration status below.', { source: m.sourcePath || sourceLabel })
				: t('cloudmigrate', 'Migration queued for "{source}" → {dest}. Progress appears below.', {
					source: m.sourcePath || sourceLabel,
					dest: m.destPath || destPath,
				});

			setInlineFeedback(icloudActionFeedback, msg, 'success');
			showFlash(msg, 'success');
			notify(msg);

			refreshStatus().then(() => {
				if (migrationStatusSection) {
					migrationStatusSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
				}
			});
		});
	});
	}

	refreshStatus();
})();
