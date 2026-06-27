@extends('layouts.admin')

@section('title')
    Server — {{ $server->name }} — DNS
@endsection

@section('content-header')
    <h1>{{ $server->name }}<small>DNS records</small></h1>
    <ol class="breadcrumb">
        <li><a href="{{ route('admin.index') }}">Admin</a></li>
        <li><a href="{{ route('admin.servers') }}">Servers</a></li>
        <li><a href="{{ route('admin.servers.view', $server->id) }}">{{ $server->name }}</a></li>
        <li class="active">DNS</li>
    </ol>
@endsection

@section('content')
@include('admin.servers.partials.navigation')
<link rel="stylesheet" href="/extensions/dnsrecords/admin-server.css">
<div class="row">
    <div class="col-xs-12">
        <div id="plugin-root-com-prestonhager-dns">
            <div class="box box-default">
                <div class="box-body text-muted">
                    <i class="fa fa-spinner fa-spin"></i> Loading DNS panel…
                </div>
            </div>
        </div>
    </div>
</div>
<script>
    window.__PterodactylPluginContext = {
        rootId: 'plugin-root-com-prestonhager-dns',
        pluginId: 'com.prestonhager.dns',
        serverId: {{ $server->id }},
        serverUuid: @json($server->uuid),
        apiBase: @json($apiBase),
        csrfToken: @json(csrf_token()),
        getPermissions: function () { return ['*']; },
        hasFullAccess: function () { return true; },
        getRootClass: function () { return 'dns-plugin-admin'; }
    };

    window.__dnsPanelBootError = function (message) {
        var root = document.getElementById('plugin-root-com-prestonhager-dns');
        if (!root) {
            return;
        }

        root.innerHTML =
            '<div class="alert alert-danger" role="alert">' +
            '<strong>DNS panel failed to load.</strong> ' +
            (message || 'Try a hard refresh or disable ad blockers for this site.') +
            '</div>';
    };

    window.__dnsPanelBoot = function () {
        if (typeof window.PterodactylPlugin_com_prestonhager_dns !== 'function') {
            window.__dnsPanelBootError('Panel script did not load.');
            return;
        }

        try {
            window.PterodactylPlugin_com_prestonhager_dns();
        } catch (err) {
            window.__dnsPanelBootError(err && err.message ? err.message : String(err));
        }
    };
</script>
<script src="/extensions/dnsrecords/server-panel.js" onerror="window.__dnsPanelBootError('Could not download panel script.')"></script>
<script>window.__dnsPanelBoot();</script>
@endsection
