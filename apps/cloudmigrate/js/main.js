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
	const icloudAuthStepStart = document.getElementById('icloud-auth-step-start');
	const icloudAuthStep2fa = document.getElementById('icloud-auth-step-2fa');
	const icloudAuthMessage = document.getElementById('icloud-auth-message');
	const icloudAuthStatus = document.getElementById('icloud-auth-status');
	const icloudMigrate = document.getElementById('icloud-migrate');
	const icloudAuthStart = document.getElementById('icloud-auth-start');
	const icloudAuthSubmit = document.getElementById('icloud-auth-submit');
	const icloudAuthRestart = document.getElementById('icloud-auth-restart');
	const icloud2faCode = document.getElementById('icloud-2fa-code');

	let pollTimer = null;
	let lastActiveMigrationCount = 0;
	let onedriveConnected = false;
	let foldersLoaded = false;
	let icloudFoldersLoaded = false;
	let icloudAuthState = '';
	let icloudAwaiting2fa = false;
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
		if (m.statusText) {
			return m.statusText;
		}
		if (m.dryRun && m.status === 'completed') {
			return t('cloudmigrate', 'Dry run complete: {count} file(s) found in {source}.', {
				count: m.totalFiles,
				source: m.sourcePath,
			});
		}
		if (m.dryRun && (m.status === 'running' || m.phase === 'scanning')) {
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
		if (m.status === 'cancelled') {
			return t('cloudmigrate', 'Migration cancelled.');
		}
		if (m.status === 'paused') {
			return t('cloudmigrate', 'Migration paused.');
		}
		if (m.status === 'failed' && m.errorMessage) {
			return m.errorMessage;
		}
		return '';
	}

	function formatProgressLabel(m) {
		if (m.phase === 'scanning' || (m.status === 'running' && m.totalFiles === 0)) {
			return m.copiedFiles + ' ' + t('cloudmigrate', 'file(s) scanned');
		}
		return m.copiedFiles + '/' + (m.totalFiles || '?');
	}

	function migrationAction(migrationId, action, btn) {
		const labels = {
			cancel: t('cloudmigrate', 'Cancelling…'),
			pause: t('cloudmigrate', 'Pausing…'),
			resume: t('cloudmigrate', 'Resuming…'),
		};
		setButtonLoading(btn, true, labels[action] || '');
		return api('/api/migrate/' + migrationId + '/' + action, { method: 'POST' }).then(({ ok, json }) => {
			setButtonLoading(btn, false);
			if (!ok) {
				notify(json.message || t('cloudmigrate', 'Action failed.'), 'error');
				return;
			}
			refreshStatus();
		});
	}

	function renderMigrations(migrations) {
		if (!migrations.length) {
			migrationList.innerHTML = '<em>' + t('cloudmigrate', 'No migrations yet.') + '</em>';
			return;
		}
		migrationList.innerHTML = migrations.map((m) => {
			const label = m.dryRun ? ' (' + t('cloudmigrate', 'dry run') + ')' : '';
			const summary = formatMigrationSummary(m);
			const staleHint = m.status === 'failed' && m.errorMessage && m.errorMessage.indexOf('Interrupted') === 0
				? '<br><span class="hint">' + t('cloudmigrate', 'This job was not running on the server (likely after a restart).') + '</span>'
				: '';
			const actions = [];
			if (m.canCancel) {
				actions.push('<button type="button" class="migration-action migration-cancel" data-id="' + m.id + '" data-action="cancel">' + t('cloudmigrate', 'Cancel') + '</button>');
			}
			if (m.canPause) {
				actions.push('<button type="button" class="migration-action migration-pause" data-id="' + m.id + '" data-action="pause">' + t('cloudmigrate', 'Pause') + '</button>');
			}
			if (m.canResume) {
				actions.push('<button type="button" class="migration-action migration-resume" data-id="' + m.id + '" data-action="resume">' + t('cloudmigrate', m.status === 'failed' ? 'Retry' : 'Resume') + '</button>');
			}
			const actionBar = actions.length
				? '<div class="migration-actions">' + actions.join(' ') + '</div>'
				: '';
			return '<div class="migration-row" data-migration-id="' + m.id + '">' +
				'<strong>' + escapeHtml(m.provider) + '</strong> ' + escapeHtml(m.sourcePath) + ' → ' + escapeHtml(m.destPath) + label +
				'<br><span class="status-' + escapeHtml(m.status) + '">' + escapeHtml(m.status) + '</span>' +
				(m.phase && m.phase !== m.status ? ' <span class="hint">(' + escapeHtml(m.phase) + ')</span>' : '') +
				' — ' + m.progress + '% (' + escapeHtml(formatProgressLabel(m)) + ')' +
				(summary ? '<br><span class="migration-detail">' + escapeHtml(summary) + '</span>' : '') +
				staleHint +
				(m.errorMessage && m.status !== 'failed' ? '<br><span class="error">' + escapeHtml(m.errorMessage) + '</span>' : '') +
				(m.errorMessage && m.status === 'failed' && !summary ? '<br><span class="error">' + escapeHtml(m.errorMessage) + '</span>' : '') +
				actionBar +
				'</div>';
		}).join('');
		migrationList.querySelectorAll('.migration-action').forEach((btn) => {
			btn.addEventListener('click', () => {
				migrationAction(parseInt(btn.dataset.id, 10), btn.dataset.action, btn);
			});
		});
	}

	function escapeHtml(s) {
		const d = document.createElement('div');
		d.textContent = s || '';
		return d.innerHTML;
	}

	function hasActiveMigrations(migrations) {
		return migrations.some((m) => m.isActive || m.status === 'queued' || m.status === 'running' || m.status === 'paused');
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
		lastActiveMigrationCount = active ? migrations.filter((m) => m.isActive || m.status === 'queued' || m.status === 'running' || m.status === 'paused').length : 0;
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

	function applyIcloudAuthUi(ic) {
		const authenticated = !!ic.authenticated;
		const authStatus = ic.authStatus || 'none';
		if (authStatus === 'needs_2fa') {
			icloudAwaiting2fa = true;
		}
		if (authenticated) {
			icloudAwaiting2fa = false;
		}
		if (ic.authState) {
			icloudAuthState = ic.authState;
		}
		const canSubmit2fa = icloudAwaiting2fa || authStatus === 'needs_2fa';

		if (icloudAuthPanel) {
			icloudAuthPanel.hidden = authenticated;
		}
		if (icloudAuthStepStart) {
			icloudAuthStepStart.hidden = authenticated;
		}
		if (icloudAuthStep2fa) {
			icloudAuthStep2fa.hidden = authenticated;
		}
		if (icloudAuthMessage) {
			if (canSubmit2fa) {
				icloudAuthMessage.textContent = t('cloudmigrate', 'Apple sent a verification code. Enter it below and click Submit code.');
			} else {
				icloudAuthMessage.textContent = t('cloudmigrate', 'Step 2: After you click Start sign-in above, enter the verification code here.');
			}
		}
		if (icloudAuthStatus) {
			if (authenticated) {
				icloudAuthStatus.hidden = false;
				icloudAuthStatus.textContent = t('cloudmigrate', 'Signed in to iCloud Drive (trust token active). Re-sign before ~30 days if migrations fail.');
			} else if (canSubmit2fa) {
				icloudAuthStatus.hidden = false;
				icloudAuthStatus.textContent = t('cloudmigrate', 'Waiting for verification code — use the field below.');
			} else if (ic.configured) {
				icloudAuthStatus.hidden = false;
				icloudAuthStatus.textContent = t('cloudmigrate', 'Credentials saved — click Start sign-in (step 1), then enter the code (step 2).');
			} else {
				icloudAuthStatus.hidden = true;
			}
		}
		if (icloudMigrate) {
			icloudMigrate.hidden = !authenticated;
		}
		if (icloudAuthStart) {
			icloudAuthStart.disabled = canSubmit2fa;
		}
		if (icloudAuthSubmit) {
			icloudAuthSubmit.disabled = !canSubmit2fa;
		}
		return { authenticated, authStatus, canSubmit2fa };
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
			const { authenticated, canSubmit2fa } = applyIcloudAuthUi(ic);
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
				icloudAwaiting2fa = false;
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
			icloudAwaiting2fa = true;
			if (icloudAuthSubmit) {
				icloudAuthSubmit.disabled = false;
			}
			if (icloudAuthStart) {
				icloudAuthStart.disabled = true;
			}
			if (icloudAuthStep2fa) {
				icloudAuthStep2fa.hidden = false;
			}
			if (!json.resumed) {
				showFlash(msg, 'success');
				notify(msg);
			}
			if (icloud2faCode) {
				icloud2faCode.focus();
			}
		} else if (json.status === 'authenticated') {
			icloudAuthState = '';
			icloudAwaiting2fa = false;
			if (icloud2faCode) {
				icloud2faCode.value = '';
			}
			showFlash(msg, 'success');
			notify(msg);
			icloudFoldersLoaded = false;
		}
		return refreshStatus();
	}

	function submitIcloud2faCode() {
		const code = icloud2faCode ? icloud2faCode.value.trim() : '';
		if (!code) {
			showFlash(t('cloudmigrate', 'Enter the verification code, then click Submit code.'), 'error');
			return;
		}
		setButtonLoading(icloudAuthSubmit, true, t('cloudmigrate', 'Verifying…'));
		api('/api/icloud/auth/continue', {
			method: 'POST',
			body: { state: icloudAuthState || '', code },
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
	}

	if (icloudAuthStart) {
		icloudAuthStart.addEventListener('click', () => {
			if (icloudAuthStart.disabled) {
				showFlash(t('cloudmigrate', 'Enter your verification code and click Submit code. Use Restart sign-in only if you need a new code.'), 'error');
				return;
			}
			setButtonLoading(icloudAuthStart, true, t('cloudmigrate', 'Contacting Apple…'));
			api('/api/icloud/auth/start', { method: 'POST', body: { restart: false } }).then(({ ok, json }) => {
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
		icloudAuthSubmit.addEventListener('click', submitIcloud2faCode);
	}

	if (icloudAuthRestart) {
		icloudAuthRestart.addEventListener('click', () => {
		icloudAuthState = '';
		icloudAwaiting2fa = false;
		if (icloud2faCode) {
			icloud2faCode.value = '';
		}
		setButtonLoading(icloudAuthRestart, true, t('cloudmigrate', 'Restarting…'));
			api('/api/icloud/auth/start', { method: 'POST', body: { restart: true } }).then(({ ok, json }) => {
				setButtonLoading(icloudAuthRestart, false);
				if (!ok) {
					const err = json.message || t('cloudmigrate', 'Restart failed.');
					showFlash(err, 'error');
					notify(err, 'error');
					return;
				}
				handleIcloudAuthResponse(json);
			});
		});
	}

	if (icloud2faCode) {
		icloud2faCode.addEventListener('keydown', (event) => {
			if (event.key === 'Enter') {
				event.preventDefault();
				submitIcloud2faCode();
			}
		});
	}

	document.getElementById('icloud-disconnect').addEventListener('click', () => {
		icloudAuthState = '';
		icloudAwaiting2fa = false;
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
