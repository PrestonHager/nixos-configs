@php
    $isAdminServerView = request()->is('admin/servers/view/*');
    $isPortForwardServerPage = request()->is('extensions/portforward/admin/servers/view/*');
    $serverId = null;

    if ($isAdminServerView) {
        $serverId = (int) request()->segment(4);
    } elseif ($isPortForwardServerPage) {
        $serverId = (int) request()->segment(6);
    }

    $serverUuid = $serverId ? optional(\Pterodactyl\Models\Server::find($serverId))->uuid : null;
    $portForwardPageUrl = $serverId ? url("/extensions/portforward/admin/servers/view/{$serverId}") : null;
@endphp

@if (($isAdminServerView || $isPortForwardServerPage) && $serverId && $serverUuid && $portForwardPageUrl)
    <script>
        document.addEventListener('DOMContentLoaded', function () {
            var nav = document.querySelector('.nav-tabs-custom .nav.nav-tabs') || document.querySelector('ul.nav-tabs');
            if (!nav || document.getElementById('portforward-server-nav')) {
                return;
            }

            var tab = document.createElement('li');
            tab.id = 'portforward-server-nav';
            @if ($isPortForwardServerPage)
            tab.className = 'active';
            @endif
            tab.innerHTML = '<a href="{{ $portForwardPageUrl }}">Network / NAT</a>';

            var manageLink = nav.querySelector('a[href*="/manage"]');
            if (manageLink && manageLink.parentElement) {
                nav.insertBefore(tab, manageLink.parentElement);
            } else {
                var deleteTab = nav.querySelector('.tab-danger');
                if (deleteTab) {
                    nav.insertBefore(tab, deleteTab);
                } else {
                    nav.appendChild(tab);
                }
            }
        });
    </script>
@endif
