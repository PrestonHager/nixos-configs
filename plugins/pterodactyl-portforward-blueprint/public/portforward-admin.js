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
        '<div class="box box-primary">' +
        '<div class="box-header with-border">' +
        '<h3 class="box-title">Desired forwards (server allocations)</h3>' +
        '<div class="box-tools">' +
        (dryRun ? '<span class="label label-warning">Dry-run</span> ' : '<span class="label label-success">Live NAT</span> ') +
        (enabled ? '' : '<span class="label label-default">Disabled</span> ') +
        '</div></div>' +
        '<div class="box-body" id="pf-allocations">Loading allocations...</div>' +
        '<div class="box-footer">' +
        '<button class="btn btn-sm btn-primary" id="pf-forward-primary">Forward primary allocation</button> ' +
        '<button class="btn btn-sm btn-default" id="pf-forward-all-pending">Forward all pending</button> ' +
        '<span class="text-muted" id="pf-status" style="margin-left:10px"></span>' +
        '</div></div>' +
        '<div class="box box-success">' +
        '<div class="box-header with-border">' +
        '<h3 class="box-title">Active NAT mappings</h3>' +
        '</div>' +
        '<div class="box-body" id="pf-mappings">Loading mappings...</div>' +
        '<div class="box-footer">' +
        '<button class="btn btn-sm btn-default" id="pf-test-connection">Test router SSH</button>' +
        '</div></div>' +
        '<p class="text-muted">Node target: <code>' + nodeLabel + '</code> at <code>' + nodeIp + '</code>. Active mappings are stored in the extension database after apply.</p>';

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

    function statusLabel(status) {
        if (status === 'active') return '<span class="label label-success">active</span>';
        if (status === 'dry_run') return '<span class="label label-warning">dry-run</span>';
        if (status === 'pending') return '<span class="label label-default">pending</span>';
        return '<span class="label label-default">' + status + '</span>';
    }

    function renderAllocations(allocations) {
        var el = document.getElementById('pf-allocations');
        if (!allocations.length) {
            el.innerHTML = '<p class="text-muted">No allocations assigned to this server.</p>';
            return;
        }

        var html = '<table class="table table-striped table-hover"><thead><tr>' +
            '<th>Allocation port</th><th>External port</th><th>Target</th><th>Protocol</th><th>Status</th><th></th>' +
            '</tr></thead><tbody>';

        allocations.forEach(function (row) {
            var target = (row.target_ip || nodeIp) + ':' + row.port;
            var external = row.mapping ? row.mapping.external_port : row.suggested_external_port;
            var primary = row.is_primary ? ' <span class="label label-info">primary</span>' : '';
            var canForward = row.forward_status === 'pending';

            html += '<tr><td><strong>' + row.port + '</strong>' + primary + '</td>';
            html += '<td><code>' + external + '</code></td>';
            html += '<td><code>' + target + '</code></td>';
            html += '<td>' + (row.protocol || 'tcp').toUpperCase() + '</td>';
            html += '<td>' + statusLabel(row.forward_status) + '</td>';
            html += '<td>';
            if (canForward) {
                html += '<button class="btn btn-xs btn-primary pf-forward-allocation" data-id="' + row.allocation_id + '">Forward</button>';
            } else if (row.mapping && row.mapping.id) {
                html += '<span class="text-muted">Mapped</span>';
            } else {
                html += '<span class="text-muted">—</span>';
            }
            html += '</td></tr>';
        });

        html += '</tbody></table>';
        el.innerHTML = html;

        document.querySelectorAll('.pf-forward-allocation').forEach(function (btn) {
            btn.addEventListener('click', function () {
                forwardAllocation(btn.dataset.id);
            });
        });
    }

    function renderMappings(mappings) {
        var el = document.getElementById('pf-mappings');
        if (!mappings.length) {
            el.innerHTML = '<p class="text-muted">No NAT mappings recorded for this server yet.</p>';
            return;
        }

        var html = '<table class="table table-striped table-hover"><thead><tr>' +
            '<th>Protocol</th><th>External port</th><th>Internal target</th><th>Status</th><th></th>' +
            '</tr></thead><tbody>';

        mappings.forEach(function (m) {
            var internalTarget = (m.inside_ip || nodeIp) + ':' + m.internal_port;
            html += '<tr><td>' + (m.protocol || 'tcp').toUpperCase() + '</td>';
            html += '<td><strong><code>' + m.external_port + '</code></strong></td>';
            html += '<td><code>' + internalTarget + '</code></td>';
            html += '<td>' + statusLabel(m.status) + '</td>';
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
            .then(function (data) {
                renderAllocations(data.allocations || []);
                renderMappings(data.mappings || []);
            })
            .catch(function () { setStatus('Failed to load port forward overview.', true); });
    }

    function forwardAllocation(allocationId) {
        setStatus('Applying forward for allocation ' + allocationId + '...');
        fetch(ctx.apiBase + '/mappings/forward-allocation/' + allocationId, { method: 'POST', headers: headers() })
            .then(function (r) { return r.json().then(function (body) { return { ok: r.ok, body: body }; }); })
            .then(function (result) {
                if (!result.ok) {
                    setStatus(result.body.error || 'Forward failed.', true);
                    return;
                }
                setStatus('Allocation forwarded.');
                load();
            })
            .catch(function () { setStatus('Forward request failed.', true); });
    }

    document.getElementById('pf-forward-primary').addEventListener('click', function () {
        setStatus('Applying primary allocation...');
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

    document.getElementById('pf-forward-all-pending').addEventListener('click', function () {
        fetch(ctx.apiBase + '/mappings', { headers: headers() })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                var pending = (data.pending || []).filter(function (row) { return row.forward_status === 'pending'; });
                if (!pending.length) {
                    setStatus('No pending allocations to forward.');
                    return;
                }
                setStatus('Forwarding ' + pending.length + ' allocation(s)...');
                var chain = Promise.resolve();
                pending.forEach(function (row) {
                    chain = chain.then(function () {
                        return fetch(ctx.apiBase + '/mappings/forward-allocation/' + row.allocation_id, {
                            method: 'POST',
                            headers: headers(),
                        }).then(function (r) { return r.json(); });
                    });
                });
                chain.then(function () {
                    setStatus('Pending allocations forwarded.');
                    load();
                }).catch(function () { setStatus('One or more forwards failed.', true); load(); });
            });
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
