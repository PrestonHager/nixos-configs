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
<div class="row">
    <div class="col-xs-12">
        <div id="plugin-root-com-prestonhager-dns"></div>
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
</script>
<script src="/extensions/dnsrecords/dns-admin.js"></script>
@endsection
