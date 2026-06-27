(function () {
    var ctx = window.__PortForwardContext;
    if (!ctx) return;

    var root = document.getElementById('plugin-root-portforward');
    if (!root) return;

    root.innerHTML = '<div class="box"><div class="box-header"><h3 class="box-title">Port forwards</h3></div><div class="box-body" id="pf-mappings">Loading...</div><div class="box-footer"><button class="btn btn-sm btn-primary" id="pf-forward-primary">Forward primary allocation</button></div></div>';

    function headers() {
        return {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-CSRF-TOKEN': ctx.csrfToken,
        };
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
            .then(function (data) { renderMappings(data.mappings || []); });
    }

    document.getElementById('pf-forward-primary').addEventListener('click', function () {
        fetch(ctx.apiBase + '/mappings/forward-primary', { method: 'POST', headers: headers() })
            .then(function (r) { return r.json(); })
            .then(function () { load(); });
    });

    load();
})();
