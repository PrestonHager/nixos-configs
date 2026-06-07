@php
    $isAdminServerView = request()->is('admin/servers/view/*');
    $serverId = $isAdminServerView ? (int) request()->segment(4) : null;
    $serverUuid = $serverId ? optional(\Pterodactyl\Models\Server::find($serverId))->uuid : null;
@endphp

@if ($isAdminServerView && $serverId && $serverUuid)
    <script>
        document.addEventListener('DOMContentLoaded', function () {
            var nav = document.querySelector('.nav-tabs');
            var content = document.querySelector('.tab-content');
            if (!nav || !content || document.getElementById('dns-tab')) {
                return;
            }

            var tab = document.createElement('li');
            tab.innerHTML = '<a href="#dns-tab" data-toggle="tab" aria-expanded="false">DNS</a>';
            nav.appendChild(tab);

            var pane = document.createElement('div');
            pane.className = 'tab-pane';
            pane.id = 'dns-tab';
            pane.innerHTML = '<div id="plugin-root-com-prestonhager-dns"></div>';
            content.appendChild(pane);

            window.__PterodactylPluginContext = {
                rootId: 'plugin-root-com-prestonhager-dns',
                pluginId: 'com.prestonhager.dns',
                serverId: {{ $serverId }},
                serverUuid: @json($serverUuid),
                apiBase: '/extensions/dnsrecords/admin/servers/{{ $serverId }}',
                csrfToken: @json(csrf_token()),
                getPermissions: function () { return ['*']; },
                hasFullAccess: function () { return true; },
                getRootClass: function () { return 'dns-plugin-admin'; }
            };

            var script = document.createElement('script');
            script.src = '/extensions/dnsrecords/dns-admin.js';
            script.onload = function () {
                if (typeof window.PterodactylPlugin_com_prestonhager_dns === 'function') {
                    window.PterodactylPlugin_com_prestonhager_dns();
                }
            };
            document.body.appendChild(script);
        });
    </script>
@endif
