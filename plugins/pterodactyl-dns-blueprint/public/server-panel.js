window.PterodactylPlugin_com_prestonhager_dns = function () {
    'use strict';

    var PLUGIN_ID = 'com.prestonhager.dns';
    var ctx = window.__PterodactylPluginContext;
    var rootId = (ctx && ctx.rootId) || ('plugin-root-' + PLUGIN_ID.replace(/\./g, '-'));
    var root = document.getElementById(rootId);

    if (!ctx || !root) {
        return;
    }

    function perms() {
        return ctx.getPermissions() || [];
    }

    function can(permission) {
        if (ctx.hasFullAccess && ctx.hasFullAccess()) {
            return true;
        }

        var p = perms();
        return p.indexOf('*') !== -1 || p.indexOf(permission) !== -1;
    }

    function csrfToken() {
        if (ctx.csrfToken) {
            return ctx.csrfToken;
        }

        var meta =
            document.querySelector('meta[name="csrf-token"]') ||
            document.querySelector('meta[name="_token"]');

        return meta ? meta.getAttribute('content') || '' : '';
    }

    function apiErrorMessage(data, fallback) {
        return (
            (data && data.errors && data.errors[0] && data.errors[0].detail) ||
            (data && data.message) ||
            fallback
        );
    }

    function parseApiResponse(response) {
        if (response.status === 204) {
            return null;
        }

        return response.text().then(function (text) {
            if (!text) {
                return null;
            }

            var data;
            try {
                data = JSON.parse(text);
            } catch (parseError) {
                throw new Error(
                    'Unexpected response from ' +
                        response.url +
                        ' (HTTP ' +
                        response.status +
                        '). Sign in again or disable ad blockers.'
                );
            }

            if (!response.ok) {
                throw new Error(apiErrorMessage(data, 'Request failed (HTTP ' + response.status + ')'));
            }

            return data;
        });
    }

    function api(path, options) {
        options = options || {};
        var url = ctx.apiBase + path;
        var headers = {
            Accept: 'application/json',
            'Content-Type': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
        };

        var token = csrfToken();
        if (token) {
            headers['X-CSRF-TOKEN'] = token;
        }

        var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
        var timeoutId = controller
            ? window.setTimeout(function () {
                  controller.abort();
              }, 30000)
            : null;

        return fetch(url, {
            credentials: 'same-origin',
            method: options.method || 'GET',
            headers: headers,
            body: options.body ? JSON.stringify(options.body) : undefined,
            signal: controller ? controller.signal : undefined,
        })
            .then(function (response) {
                if (timeoutId) {
                    window.clearTimeout(timeoutId);
                }
                return parseApiResponse(response);
            })
            .catch(function (err) {
                if (timeoutId) {
                    window.clearTimeout(timeoutId);
                }
                if (err && err.name === 'AbortError') {
                    throw new Error('Request timed out: ' + url);
                }
                if (err && err.message) {
                    throw err;
                }
                throw new Error('Network error loading ' + url);
            });
    }

    function serverPath(suffix) {
        return suffix;
    }

    function adminApi(path, options) {
        options = options || {};
        var url = '/api/plugins-admin/' + PLUGIN_ID + path;
        var headers = {
            Accept: 'application/json',
            'Content-Type': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
        };
        var token = csrfToken();
        if (token) {
            headers['X-CSRF-TOKEN'] = token;
        }
        return fetch(url, {
            credentials: 'same-origin',
            method: options.method || 'GET',
            headers: headers,
            body: options.body ? JSON.stringify(options.body) : undefined,
        }).then(parseApiResponse);
    }

    function escapeHtml(text) {
        var div = document.createElement('div');
        div.textContent = text == null ? '' : String(text);
        return div.innerHTML;
    }

    function pluginClass() {
        if (ctx.getRootClass && typeof ctx.getRootClass === 'function') {
            return ctx.getRootClass();
        }
        return 'ptero-plugin';
    }

    function defaultRecordForm(overrides, srvDefaults) {
        var d = overrides || srvDefaults || {};
        return {
            type: d.record_type || 'SRV',
            name: d.name || '',
            target: d.target || '',
            port: d.port || 25565,
            service: d.service || '_minecraft',
            proto: d.proto || '_tcp',
            priority: d.priority != null ? d.priority : 0,
            weight: d.weight != null ? d.weight : 5,
        };
    }

    var state = {
        subdomain: null,
        profiles: [],
        enabled: [],
        records: [],
        defaults: null,
        loading: true,
        error: '',
        showRecordForm: false,
        recordForm: defaultRecordForm(null, null),
        submitting: false,
        adminLabelDraft: '',
        adminDomainDraft: 'default',
        adminLocked: false,
    };

    function render() {
        root.innerHTML =
            '<div class="box box-primary ' +
            pluginClass() +
            '">' +
            '<div class="box-header with-border">' +
            '<h3 class="box-title"><i class="fa fa-globe"></i> DNS Administration</h3>' +
            '</div>' +
            '<div class="box-body">' +
            (state.error ? '<div class="alert alert-danger" role="alert">' + escapeHtml(state.error) + '</div>' : '') +
            (state.loading
                ? '<p class="text-muted"><i class="fa fa-spinner fa-spin"></i> Loading DNS data…</p>'
                : renderContent()) +
            '</div></div>';
    }

    function renderContent() {
        return renderSubdomainSection() + renderProfilesSection() + renderRecordsSection();
    }

    function renderSubdomainSection() {
        var sub = state.subdomain || {};
        var html =
            '<div class="ptero-plugin-box"><h3>Hostname</h3>' +
            '<p>Mode: <strong>' +
            escapeHtml(sub.hostname_mode || 'auto') +
            '</strong> — FQDN: <code>' +
            escapeHtml(sub.fqdn || '') +
            '</code></p>' +
            '<div class="ptero-field"><label class="ptero-label" for="admin-dns-label">Override label</label>' +
            '<input class="ptero-input" id="admin-dns-label" type="text" value="' +
            escapeHtml(state.adminLabelDraft || sub.hostname_label || '') +
            '"></div>';

        if ((sub.primary_domains || []).length > 0) {
            html += '<div class="ptero-field"><label class="ptero-label" for="admin-dns-domain">Primary domain</label><select class="ptero-select" id="admin-dns-domain">';
            (sub.primary_domains || []).forEach(function (d) {
                var selected = (state.adminDomainDraft || sub.primary_domain) === d.id ? ' selected' : '';
                html +=
                    '<option value="' +
                    escapeHtml(d.id) +
                    '"' +
                    selected +
                    '>' +
                    escapeHtml(d.domain) +
                    '</option>';
            });
            html += '</select></div>';
        }

        html +=
            '<div class="ptero-profile-row">' +
            '<input type="checkbox" id="admin-dns-locked"' +
            (state.adminLocked || sub.subdomain_locked ? ' checked' : '') +
            '>' +
            '<label for="admin-dns-locked">Lock hostname (block client changes)</label></div>' +
            '<div class="ptero-plugin-actions">' +
            '<button type="button" class="ptero-btn ptero-btn--primary" data-action="save-subdomain">Save hostname</button>' +
            '<button type="button" class="ptero-btn ptero-btn--secondary" data-action="regenerate-subdomain">Regenerate</button>' +
            '<button type="button" class="ptero-btn ptero-btn--secondary" data-action="sync-profiles">Reconcile SRV</button>' +
            '</div>' +
            '<p class="ptero-hint">Changes: ' +
            escapeHtml(String(sub.label_change_count || 0)) +
            (sub.last_label_change_at ? ' — last ' + escapeHtml(sub.last_label_change_at) : '') +
            '</p></div>';

        return html;
    }

    function renderProfilesSection() {
        if (!can('records.read')) {
            return '';
        }

        var html =
            '<div class="ptero-plugin-box"><h3>SRV Profiles</h3>' +
            '<p>Enable game/service SRV records (Minecraft TCP, Factorio UDP, etc.) for this server.</p>';

        if (state.profiles.length === 0) {
            html +=
                '<p class="ptero-muted">No SRV profiles configured. Add <code>srv_profiles</code> in Admin → Plugins → Settings.</p>';
        }

        state.profiles.forEach(function (profile) {
            var checked = state.enabled.indexOf(profile.id) !== -1 ? ' checked' : '';
            var disabled = can('records.update') ? '' : ' disabled';
            html +=
                '<div class="ptero-profile-row">' +
                '<input type="checkbox" data-profile-id="' +
                escapeHtml(profile.id) +
                '"' +
                checked +
                disabled +
                ' id="profile-' +
                escapeHtml(profile.id) +
                '">' +
                '<label for="profile-' +
                escapeHtml(profile.id) +
                '">' +
                escapeHtml(profile.label) +
                ' <code>' +
                escapeHtml(profile.service + profile.proto) +
                '</code></label></div>';
        });

        if (can('records.update') && state.profiles.length > 0) {
            html +=
                '<div class="ptero-plugin-actions">' +
                '<button type="button" class="ptero-btn ptero-btn--primary" data-action="save-profiles">Save profiles</button>' +
                '<button type="button" class="ptero-btn ptero-btn--secondary" data-action="sync-profiles">Sync SRV records</button>' +
                '</div>';
        }

        return html + '</div>';
    }

    function renderRecordsSection() {
        var html = '<div class="ptero-plugin-box"><h3>Records</h3>';

        if (can('records.create')) {
            html += '<div class="ptero-plugin-actions">';
            if (!state.showRecordForm) {
                html +=
                    '<button type="button" class="ptero-btn ptero-btn--primary" data-action="toggle-record-form">Add record</button>';
            } else {
                html +=
                    '<button type="button" class="ptero-btn ptero-btn--secondary" data-action="toggle-record-form">Cancel</button>';
            }
            html += '</div>';
        }

        if (state.showRecordForm && can('records.create')) {
            html += renderRecordForm();
        }

        html += '<table class="ptero-table"><thead><tr><th>Type</th><th>Name</th><th>Details</th><th></th></tr></thead><tbody>';

        if (state.records.length === 0) {
            html += '<tr><td colspan="4" class="ptero-muted">No records yet.</td></tr>';
        } else {
            state.records.forEach(function (record) {
                var details = record.content || '';
                if (record.type === 'SRV') {
                    details =
                        (record.service || '') +
                        (record.proto || '') +
                        ' → ' +
                        (record.data && record.data.target ? record.data.target : record.target || '') +
                        ':' +
                        (record.port || (record.data && record.data.port) || '');
                } else if (record.type === 'CNAME') {
                    details = '→ ' + (record.content || record.target || '');
                }
                if (record.profile_id) {
                    details = (record.label || record.profile_id) + ' — ' + details;
                }

                html +=
                    '<tr><td>' +
                    escapeHtml(record.type) +
                    '</td><td>' +
                    escapeHtml(record.name) +
                    '</td><td>' +
                    escapeHtml(details) +
                    '</td><td>';

                if (can('records.delete')) {
                    var recordId = record.record_id || record.cloudflare_id || '';
                    html +=
                        '<button type="button" class="ptero-btn ptero-btn--danger ptero-btn--sm" data-action="delete-record" data-id="' +
                        escapeHtml(recordId) +
                        '" data-name="' +
                        escapeHtml(record.name || '') +
                        '" data-type="' +
                        escapeHtml(record.type || '') +
                        '">Delete</button>';
                }

                html += '</td></tr>';
            });
        }

        return html + '</tbody></table></div>';
    }

    function renderRecordForm() {
        var f = state.recordForm;
        var type = f.type || 'SRV';
        var baseDomain = (state.defaults && state.defaults.base_domain) || '';

        return (
            '<div class="ptero-plugin-panel" id="dns-record-form">' +
            '<h4>New DNS record</h4>' +
            '<div class="ptero-field"><label class="ptero-label" for="dns-type">Type</label>' +
            '<select class="ptero-select" id="dns-type">' +
            ['SRV', 'A', 'AAAA', 'CNAME', 'MX', 'TXT']
                .map(function (t) {
                    return '<option value="' + t + '"' + (type === t ? ' selected' : '') + '>' + t + '</option>';
                })
                .join('') +
            '</select></div>' +
            '<div class="ptero-field"><label class="ptero-label" for="dns-name">Name</label>' +
            '<input class="ptero-input" id="dns-name" type="text" placeholder="subdomain or FQDN" value="' +
            escapeHtml(f.name || '') +
            '">' +
            '<p class="ptero-hint">Enter a subdomain (e.g. <code>mc</code>) or full name (e.g. <code>mc' +
            (baseDomain ? '.' + escapeHtml(baseDomain) : '.example.com') +
            '</code>).</p></div>' +
            '<div id="dns-type-fields">' +
            renderTypeFields(type) +
            '</div>' +
            '<div class="ptero-plugin-actions">' +
            '<button type="button" class="ptero-btn ptero-btn--primary" data-action="submit-record"' +
            (state.submitting ? ' disabled' : '') +
            '>' +
            (state.submitting ? 'Creating…' : 'Create record') +
            '</button>' +
            '<button type="button" class="ptero-btn ptero-btn--secondary" data-action="toggle-record-form">Cancel</button>' +
            '</div></div>'
        );
    }

    function renderTypeFields(type) {
        var f = state.recordForm;
        if (type === 'SRV') {
            return (
                '<div class="ptero-field"><label class="ptero-label" for="dns-service">Service</label>' +
                '<input class="ptero-input" id="dns-service" type="text" placeholder="_minecraft" value="' +
                escapeHtml(f.service || '_minecraft') +
                '"></div>' +
                '<div class="ptero-field"><label class="ptero-label" for="dns-proto">Protocol</label>' +
                '<select class="ptero-select" id="dns-proto">' +
                '<option value="_tcp"' +
                (f.proto === '_tcp' ? ' selected' : '') +
                '>TCP (_tcp)</option>' +
                '<option value="_udp"' +
                (f.proto === '_udp' ? ' selected' : '') +
                '>UDP (_udp)</option></select></div>' +
                '<div class="ptero-field"><label class="ptero-label" for="dns-target">Target</label>' +
                '<input class="ptero-input" id="dns-target" type="text" placeholder="host.example.com" value="' +
                escapeHtml(f.target || '') +
                '"></div>' +
                '<div class="ptero-field"><label class="ptero-label" for="dns-port">Port</label>' +
                '<input class="ptero-input" id="dns-port" type="number" value="' +
                escapeHtml(String(f.port || 25565)) +
                '"></div>' +
                '<div class="ptero-field"><label class="ptero-label" for="dns-priority">Priority</label>' +
                '<input class="ptero-input" id="dns-priority" type="number" value="' +
                escapeHtml(String(f.priority != null ? f.priority : 0)) +
                '"></div>' +
                '<div class="ptero-field"><label class="ptero-label" for="dns-weight">Weight</label>' +
                '<input class="ptero-input" id="dns-weight" type="number" value="' +
                escapeHtml(String(f.weight != null ? f.weight : 5)) +
                '"></div>'
            );
        }
        if (type === 'MX') {
            return (
                '<div class="ptero-field"><label class="ptero-label" for="dns-content">Mail server</label>' +
                '<input class="ptero-input" id="dns-content" type="text" placeholder="mail.example.com"></div>' +
                '<div class="ptero-field"><label class="ptero-label" for="dns-priority">Priority</label>' +
                '<input class="ptero-input" id="dns-priority" type="number" value="10"></div>'
            );
        }
        return (
            '<div class="ptero-field"><label class="ptero-label" for="dns-content">Content</label>' +
            '<input class="ptero-input" id="dns-content" type="text" placeholder="Record value"></div>'
        );
    }

    function handleClick(event) {
        var target = event.target;
        if (!target || !root.contains(target)) {
            return;
        }

        var actionEl = target.closest('[data-action]');
        if (!actionEl || !root.contains(actionEl)) {
            return;
        }

        var action = actionEl.getAttribute('data-action');

        if (action === 'save-profiles') {
            saveProfiles();
            return;
        }

        if (action === 'sync-profiles') {
            syncProfiles();
            return;
        }

        if (action === 'toggle-record-form') {
            state.showRecordForm = !state.showRecordForm;
            if (state.showRecordForm) {
                state.recordForm = defaultRecordForm(null, state.defaults);
            }
            state.error = '';
            render();
            return;
        }

        if (action === 'delete-record') {
            deleteRecord(
                actionEl.getAttribute('data-id'),
                actionEl.getAttribute('data-name'),
                actionEl.getAttribute('data-type')
            );
            return;
        }

        if (action === 'submit-record') {
            submitRecord();
            return;
        }

        if (action === 'save-subdomain') {
            saveSubdomain();
            return;
        }

        if (action === 'regenerate-subdomain') {
            regenerateSubdomain();
        }
    }

    function handleChange(event) {
        var target = event.target;
        if (!target || !root.contains(target)) {
            return;
        }

        if (target.id === 'dns-type') {
            state.recordForm.type = target.value;
            render();
            return;
        }

        if (target.id === 'dns-name') {
            state.recordForm.name = target.value;
        }

        if (target.id === 'admin-dns-label') {
            state.adminLabelDraft = target.value;
        }

        if (target.id === 'admin-dns-domain') {
            state.adminDomainDraft = target.value;
        }

        if (target.id === 'admin-dns-locked') {
            state.adminLocked = target.checked;
        }
    }

    function bindRootEvents() {
        if (root.dataset.pteroEventsBound === 'true') {
            return;
        }

        root.dataset.pteroEventsBound = 'true';
        root.addEventListener('click', handleClick);
        root.addEventListener('change', handleChange);
    }

    function applyLoadResult(key, data) {
        if (key === 'subdomain') {
            state.subdomain = (data && data.attributes) || {};
            state.adminLabelDraft = state.subdomain.hostname_label || '';
            state.adminDomainDraft = state.subdomain.primary_domain || 'default';
            state.adminLocked = !!state.subdomain.subdomain_locked;
            return;
        }

        if (key === 'profiles') {
            state.profiles = (data && data.attributes && data.attributes.profiles) || [];
            state.enabled = (data && data.attributes && data.attributes.enabled) || [];
            state.defaults = (data && data.attributes && data.attributes.defaults) || null;
            return;
        }

        if (key === 'records') {
            state.records = (data && data.data) || [];
        }
    }

    function load() {
        state.loading = true;
        state.error = '';
        render();

        var endpoints = [
            { key: 'subdomain', path: '/subdomain' },
            { key: 'profiles', path: '/srv-profiles' },
            { key: 'records', path: '/records' },
        ];

        Promise.all(
            endpoints.map(function (endpoint) {
                return api(serverPath(endpoint.path))
                    .then(function (data) {
                        return { key: endpoint.key, ok: true, data: data };
                    })
                    .catch(function (err) {
                        return {
                            key: endpoint.key,
                            ok: false,
                            error: err && err.message ? err.message : String(err),
                        };
                    });
            })
        ).then(function (results) {
            var errors = [];

            results.forEach(function (result) {
                if (result.ok) {
                    applyLoadResult(result.key, result.data);
                    return;
                }

                errors.push(result.key + ': ' + result.error);
            });

            state.loading = false;
            state.error = errors.join(' · ');
            render();
        });
    }

    function saveProfiles() {
        var enabled = [];
        root.querySelectorAll('input[data-profile-id]').forEach(function (input) {
            if (input.checked) {
                enabled.push(input.getAttribute('data-profile-id'));
            }
        });

        state.error = '';
        api(serverPath('/srv-profiles'), { method: 'PUT', body: { enabled: enabled } })
            .then(load)
            .catch(function (err) {
                state.error = err.message;
                render();
            });
    }

    function syncProfiles() {
        state.error = '';
        api(serverPath('/srv-profiles/sync'), { method: 'POST', body: {} })
            .then(load)
            .catch(function (err) {
                state.error = err.message;
                render();
            });
    }

    function deleteRecord(id, name, type) {
        if (!confirm('Delete this DNS record?')) {
            return;
        }
        state.error = '';
        var path = '/records/' + encodeURIComponent(id);
        var query = [];
        if (name) {
            query.push('name=' + encodeURIComponent(name));
        }
        if (type) {
            query.push('type=' + encodeURIComponent(type));
        }
        if (query.length > 0) {
            path += '?' + query.join('&');
        }
        var request;
        if (String(id).indexOf(':') !== -1) {
            request = api(serverPath('/records/delete'), {
                method: 'POST',
                body: { record_id: id, name: name || '', type: type || '' },
            });
        } else {
            request = api(serverPath(path), { method: 'DELETE' });
        }
        request
            .then(load)
            .catch(function (err) {
                state.error = err.message;
                render();
            });
    }

    function submitRecord() {
        var typeEl = root.querySelector('#dns-type');
        var nameEl = root.querySelector('#dns-name');
        if (!typeEl || !nameEl) {
            return;
        }

        var type = typeEl.value;
        var name = nameEl.value.trim();
        if (!name) {
            state.error = 'Name is required.';
            render();
            return;
        }

        var body = { type: type, name: name };

        if (type === 'SRV') {
            body.data = {
                service: root.querySelector('#dns-service').value,
                proto: root.querySelector('#dns-proto').value,
                target: root.querySelector('#dns-target').value,
                port: parseInt(root.querySelector('#dns-port').value, 10),
                priority: parseInt(root.querySelector('#dns-priority').value, 10),
                weight: parseInt(root.querySelector('#dns-weight').value, 10),
            };
        } else if (type === 'MX') {
            body.content = root.querySelector('#dns-content').value;
            body.priority = parseInt(root.querySelector('#dns-priority').value, 10);
        } else {
            body.content = root.querySelector('#dns-content').value;
        }

        state.error = '';
        state.submitting = true;
        render();

        api(serverPath('/records'), { method: 'POST', body: body })
            .then(function () {
                state.showRecordForm = false;
                state.recordForm = defaultRecordForm(null, state.defaults);
                state.submitting = false;
                return load();
            })
            .catch(function (err) {
                state.submitting = false;
                state.error = err.message;
                render();
            });
    }

    function saveSubdomain() {
        var labelEl = root.querySelector('#admin-dns-label');
        var domainEl = root.querySelector('#admin-dns-domain');
        var lockedEl = root.querySelector('#admin-dns-locked');
        var label = labelEl ? labelEl.value.trim() : state.adminLabelDraft;
        if (!label) {
            state.error = 'Label is required.';
            render();
            return;
        }
        state.error = '';
        api(serverPath('/subdomain'), {
            method: 'PUT',
            body: {
                label: label,
                primary_domain: domainEl ? domainEl.value : state.adminDomainDraft,
                subdomain_locked: lockedEl ? lockedEl.checked : state.adminLocked,
            },
        })
            .then(load)
            .catch(function (err) {
                state.error = err.message;
                render();
            });
    }

    function regenerateSubdomain() {
        if (!confirm('Regenerate hostname? This will rename DNS records for this server.')) {
            return;
        }
        state.error = '';
        api(serverPath('/subdomain/regenerate'), { method: 'POST', body: {} })
            .then(load)
            .catch(function (err) {
                state.error = err.message;
                render();
            });
    }

    if (root.dataset.dnsPanelInit === 'true') {
        return;
    }

    root.dataset.dnsPanelInit = 'true';
    bindRootEvents();
    load();
};

