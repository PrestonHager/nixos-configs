@php
    $isAdminServerView = request()->is('admin/servers/view/*');
    $isDnsServerPage = request()->is('extensions/dnsrecords/admin/servers/view/*');
    $serverId = null;

    if ($isAdminServerView) {
        $serverId = (int) request()->segment(4);
    } elseif ($isDnsServerPage) {
        $serverId = (int) request()->segment(6);
    }

    $serverUuid = $serverId ? optional(\Pterodactyl\Models\Server::find($serverId))->uuid : null;
    $dnsPageUrl = $serverId ? url("/extensions/dnsrecords/admin/servers/view/{$serverId}") : null;
@endphp

@if (($isAdminServerView || $isDnsServerPage) && $serverId && $serverUuid && $dnsPageUrl)
    <script>
        document.addEventListener('DOMContentLoaded', function () {
            var nav = document.querySelector('.nav-tabs-custom .nav.nav-tabs') || document.querySelector('ul.nav-tabs');
            if (!nav || document.getElementById('dnsrecords-server-nav')) {
                return;
            }

            var tab = document.createElement('li');
            tab.id = 'dnsrecords-server-nav';
            @if ($isDnsServerPage)
            tab.className = 'active';
            @endif
            tab.innerHTML = '<a href="{{ $dnsPageUrl }}">DNS</a>';

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
