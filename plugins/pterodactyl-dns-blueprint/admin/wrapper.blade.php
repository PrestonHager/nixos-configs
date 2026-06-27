@php
    $isAdminServerView = request()->is('admin/servers/view/*');
    $isDnsServerPage = request()->is('extensions/dnsrecords/admin/servers/view/*');
    $isPortForwardServerPage = request()->is('extensions/portforward/admin/servers/view/*');
    $serverId = null;

    if ($isAdminServerView) {
        $serverId = (int) request()->segment(4);
    } elseif ($isDnsServerPage || $isPortForwardServerPage) {
        $serverId = (int) request()->segment(6);
    }

    $serverUuid = $serverId ? optional(\Pterodactyl\Models\Server::find($serverId))->uuid : null;
    $dnsPageUrl = $serverId ? url("/extensions/dnsrecords/admin/servers/view/{$serverId}") : null;
    $portForwardPageUrl = $serverId ? url("/extensions/portforward/admin/servers/view/{$serverId}") : null;
@endphp

@if (($isAdminServerView || $isDnsServerPage || $isPortForwardServerPage) && $serverId && $serverUuid && $dnsPageUrl && $portForwardPageUrl)
    <script>
        document.addEventListener('DOMContentLoaded', function () {
            var nav = document.querySelector('.nav-tabs-custom .nav.nav-tabs') || document.querySelector('ul.nav-tabs');
            if (!nav) {
                return;
            }

            function insertBeforeManage(tab) {
                var manageLink = nav.querySelector('a[href*="/manage"]');
                if (manageLink && manageLink.parentElement) {
                    nav.insertBefore(tab, manageLink.parentElement);
                    return;
                }
                var deleteTab = nav.querySelector('.tab-danger');
                if (deleteTab) {
                    nav.insertBefore(tab, deleteTab);
                    return;
                }
                nav.appendChild(tab);
            }

            if (!document.getElementById('dnsrecords-server-nav')) {
                var dnsTab = document.createElement('li');
                dnsTab.id = 'dnsrecords-server-nav';
                @if ($isDnsServerPage)
                dnsTab.className = 'active';
                @endif
                dnsTab.innerHTML = '<a href="{{ $dnsPageUrl }}">DNS</a>';
                insertBeforeManage(dnsTab);
            }

            if (!document.getElementById('portforward-server-nav')) {
                var pfTab = document.createElement('li');
                pfTab.id = 'portforward-server-nav';
                @if ($isPortForwardServerPage)
                pfTab.className = 'active';
                @endif
                pfTab.innerHTML = '<a href="{{ $portForwardPageUrl }}">Network / NAT</a>';
                insertBeforeManage(pfTab);
            }
        });
    </script>
@endif
