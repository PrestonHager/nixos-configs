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
            if (!nav || !content || document.getElementById('portforward-tab')) {
                return;
            }

            var tab = document.createElement('li');
            tab.innerHTML = '<a href="#portforward-tab" data-toggle="tab" aria-expanded="false">Network / NAT</a>';
            nav.appendChild(tab);

            var pane = document.createElement('div');
            pane.className = 'tab-pane';
            pane.id = 'portforward-tab';
            pane.innerHTML = '<div id="plugin-root-portforward"></div>';
            content.appendChild(pane);

            window.__PortForwardContext = {
                serverId: {{ $serverId }},
                apiBase: '/extensions/portforward/admin/servers/{{ $serverId }}',
                csrfToken: @json(csrf_token()),
            };

            var script = document.createElement('script');
            script.src = '/extensions/portforward/portforward-admin.js';
            document.body.appendChild(script);
        });
    </script>
@endif
