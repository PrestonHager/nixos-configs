(function () {
    var ctx = window.__PortForwardContext;
    if (!ctx) return;

    var root = document.getElementById('plugin-root-portforward');
    if (!root) return;

    var dryRun = ctx.settings && ctx.settings.dry_run;
    var enabled = ctx.settings && ctx.settings.enabled;
    var nodeLabel = ctx.node && ctx.node.name ? ctx.node.name : 'node';
    var nodeIp = ctx.node && ctx.node.lan_ip ? ctx.node.lan_ip : 'unknown';

    root.innerHTML =
        '<div class="box">' +
        '<div class="box-header with-border">' +
        '<h3 class="box-title">Port forwards</h3>' +
        '<div class="box-tools">' +
        (dryRun ? '<span class="label label-warning">Dry-run</span> ' : '<span class="label label-success">Live NAT</span> ') +
        (enabled ? '' : '<span class="label label-default">Disabled</span>') +
        '</div></div>' +
        '<div class="box-body" id="pf-mappings">Loading...</div>' +
        '<div class="box-footer">' +
        '<button class="btn btn-sm btn-primary" id="pf-forward-primary">Forward primary allocation</button> ' +
        '<button class="btn btn-sm btn-default" id="pf-test-connection">Test router SSH</button>' +
        '<span class="text-muted" id="pf-status" style="margin-left:10px"></span>' +
        '</div></div>' +
        '<p class="text-muted">Target: <code>' + nodeLabel + '</code> at <code>' + nodeIp + '</code></p>';

    function headers() {
        return {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-CSRF-TOKEN': ctx.csrfToken,
        };
    }

    function setStatus(message, isError) {
        var el = document.getElementById('pf-status');
        if (!el) return;
        el.textContent = message || '';
        el.className = isError ? 'text-danger' : 'text-muted';
    }

    function renderMappings(mappings) {
        var el = document.getElementById('pf-mappings');
        if (!mappings.length) {
            el.innerHTML = '<p class="text-muted">No active NAT mappings for this server.</p>';
            return;
        }
        var html = '<table class="table table-striped"><thead><tr><th>Protocol</th><th>External</th><th>Internal</th><th>Status</th><th></th></tr></thead><tbody>';
        mappings.forEach(function (m) {
            html += '<tr><td>' + m.protocol + '</td><td>' + m.external_port + '</td><td>' + m.internal_port + '</td><td>' + m.status + '</td>';
            html += '<td><button class="btn btn-xs btn-danger pf-remove" data-id="' + m.id + '">Remove</button></td></tr>';
        });
        html += '</tbody></table>';
        el.innerHTML = html;
        document.querySelectorAll('.pf-remove').forEach(function (btn) {
            btn.addEventListener('click', function () {
                fetch(ctx.apiBase + '/mappings/' + btn.dataset.id, { method: 'DELETE', headers: headers() })
                    .then(function () { load(); });
            });
        });
    }

    function load() {
        fetch(ctx.apiBase + '/mappings', { headers: headers() })
            .then(function (r) { return r.json(); })
            .then(function (data) { renderMappings(data.mappings || []); })
            .catch(function () { setStatus('Failed to load mappings.', true); });
    }

    document.getElementById('pf-forward-primary').addEventListener('click', function () {
        setStatus('Applying...');
        fetch(ctx.apiBase + '/mappings/forward-primary', { method: 'POST', headers: headers() })
            .then(function (r) { return r.json().then(function (body) { return { ok: r.ok, body: body }; }); })
            .then(function (result) {
                if (!result.ok) {
                    setStatus(result.body.error || 'Forward failed.', true);
                    return;
                }
                setStatus('Primary allocation forwarded.');
                load();
            })
            .catch(function () { setStatus('Forward request failed.', true); });
    });

    document.getElementById('pf-test-connection').addEventListener('click', function () {
        setStatus('Testing SSH...');
        fetch('/extensions/portforward/admin/settings/test-connection', { method: 'POST', headers: headers() })
            .then(function (r) { return r.json().then(function (body) { return { ok: r.ok, body: body }; }); })
            .then(function (result) {
                if (!result.ok) {
                    setStatus(result.body.error || result.body.message || 'Connection failed.', true);
                    return;
                }
                setStatus(result.body.success ? 'Router SSH OK.' : (result.body.stderr || 'Connection failed.'), !result.body.success);
            })
            .catch(function () { setStatus('Connection test failed.', true); });
    });

    load();
})();
