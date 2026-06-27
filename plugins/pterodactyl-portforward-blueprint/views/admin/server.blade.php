@extends('layouts.admin')

@section('title')
    Server — {{ $server->name }} — Network / NAT
@endsection

@section('content-header')
    <h1>{{ $server->name }}<small>Port forwarding</small></h1>
    <ol class="breadcrumb">
        <li><a href="{{ route('admin.index') }}">Admin</a></li>
        <li><a href="{{ route('admin.servers') }}">Servers</a></li>
        <li><a href="{{ route('admin.servers.view', $server->id) }}">{{ $server->name }}</a></li>
        <li class="active">Network / NAT</li>
    </ol>
@endsection

@section('content')
@include('admin.servers.partials.navigation')

@if (!($settings['enabled'] ?? false))
    <div class="alert alert-warning">
        Port Forward extension is disabled. Enable it under <a href="/admin/extensions/portforward">Admin → Extensions → Port Forward</a>.
    </div>
@elseif ($settings['dry_run'] ?? true)
    <div class="alert alert-info">
        <strong>Dry-run mode</strong> — NAT commands are logged but not applied to the router.
    </div>
@endif

<div class="row">
    <div class="col-xs-12">
        <div class="box box-default">
            <div class="box-header with-border">
                <h3 class="box-title">Node target</h3>
            </div>
            <div class="box-body">
                <dl class="dl-horizontal">
                    <dt>Node</dt>
                    <dd>{{ $server->node->name ?? 'Unknown' }} (ID {{ $server->node_id }})</dd>
                    <dt>LAN IP</dt>
                    <dd>
                        @if ($nodeTarget)
                            <code>{{ $nodeTarget }}</code>
                        @elseif ($nodeTargetError)
                            <span class="text-danger">{{ $nodeTargetError }}</span>
                        @else
                            <span class="text-muted">Not configured</span>
                        @endif
                    </dd>
                    <dt>Router</dt>
                    <dd><code>{{ $settings['router_host'] ?? '192.168.5.1' }}</code> ({{ $settings['wan_interface'] ?? 'GigabitEthernet0/0' }})</dd>
                </dl>
            </div>
        </div>

        <div id="plugin-root-portforward"></div>
    </div>
</div>
<script>
    window.__PortForwardContext = {
        serverId: {{ $server->id }},
        apiBase: @json($apiBase),
        csrfToken: @json(csrf_token()),
        settings: @json([
            'enabled' => (bool) ($settings['enabled'] ?? false),
            'dry_run' => (bool) ($settings['dry_run'] ?? true),
        ]),
        node: @json([
            'name' => $server->node->name ?? null,
            'lan_ip' => $nodeTarget,
        ]),
    };
</script>
<script src="/extensions/portforward/portforward-admin.js"></script>
@endsection
