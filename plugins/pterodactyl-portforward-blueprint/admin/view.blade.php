@extends('layouts.admin')

@section('title')
    Port Forward
@endsection

@section('content-header')
    <h1>Port Forward<small>Astracap router NAT for game servers</small></h1>
    <ol class="breadcrumb">
        <li><a href="{{ route('admin.index') }}">Admin</a></li>
        <li class="active">Extensions</li>
        <li class="active">Port Forward</li>
    </ol>
@endsection

@section('content')
<div class="row">
    <div class="col-xs-12">
        @if ($settings['dry_run'] ?? true)
            <div class="alert alert-warning">
                <strong>Dry-run mode is ON.</strong> IOS commands are logged but not applied to the router until you disable dry-run and enable the extension.
            </div>
        @endif
        <div class="box">
            <div class="box-header with-border">
                <h3 class="box-title">Router connection</h3>
            </div>
            <form action="{{ $root }}" method="POST">
                @csrf
                @method('PATCH')
                <div class="box-body">
                    <div class="checkbox">
                        <input type="checkbox" id="pf_enabled" name="enabled" value="1" @checked(old('enabled', $settings['enabled'] ?? false))>
                        <label for="pf_enabled">Enable extension</label>
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="pf_dry_run" name="dry_run" value="1" @checked(old('dry_run', $settings['dry_run'] ?? true))>
                        <label for="pf_dry_run">Dry-run mode (log only)</label>
                    </div>
                    <div class="form-group">
                        <label for="router_host">Router host</label>
                        <input type="text" class="form-control" id="router_host" name="router_host" value="{{ old('router_host', $settings['router_host'] ?? '192.168.5.1') }}">
                    </div>
                    <div class="form-group">
                        <label for="router_ssh_user">SSH user</label>
                        <input type="text" class="form-control" id="router_ssh_user" name="router_ssh_user" value="{{ old('router_ssh_user', $settings['router_ssh_user'] ?? 'prestonh') }}">
                    </div>
                    <div class="form-group">
                        <label for="router_ssh_private_key">SSH private key</label>
                        <textarea class="form-control" id="router_ssh_private_key" name="router_ssh_private_key" rows="4" placeholder="Leave blank to keep existing or use sops-mounted key file"></textarea>
                        <p class="help-block">Prefer <code>PORTFORWARD_SSH_KEY_FILE</code> from sops-nix (not stored in git).</p>
                    </div>
                    <div class="form-group">
                        <label for="wan_interface">WAN interface</label>
                        <input type="text" class="form-control" id="wan_interface" name="wan_interface" value="{{ old('wan_interface', $settings['wan_interface'] ?? 'GigabitEthernet0/0') }}">
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="pf_auto_forward_on_install" name="auto_forward_on_install" value="1" @checked(old('auto_forward_on_install', $settings['auto_forward_on_install'] ?? false))>
                        <label for="pf_auto_forward_on_install">Auto-forward primary allocation on server install</label>
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="pf_auto_remove_on_delete" name="auto_remove_on_delete" value="1" @checked(old('auto_remove_on_delete', $settings['auto_remove_on_delete'] ?? true))>
                        <label for="pf_auto_remove_on_delete">Auto-remove mappings on server delete</label>
                    </div>
                    <div class="form-group">
                        <label for="node_ip_map_json">Node IP map (JSON)</label>
                        <textarea class="form-control" id="node_ip_map_json" name="node_ip_map_json" rows="4">{{ old('node_ip_map_json', json_encode($settings['node_ip_map'] ?? [], JSON_PRETTY_PRINT)) }}</textarea>
                        <p class="help-block">Example: <code>{"1": "192.168.5.6", "2": "192.168.5.7"}</code></p>
                    </div>
                    <div class="form-group">
                        <label for="blocked_ports_json">Blocked ports (JSON array)</label>
                        <textarea class="form-control" id="blocked_ports_json" name="blocked_ports_json" rows="2">{{ old('blocked_ports_json', json_encode($settings['blocked_ports'] ?? [22,80,443,3380])) }}</textarea>
                    </div>
                </div>
                <div class="box-footer">
                    <button type="submit" class="btn btn-primary pull-right">Save settings</button>
                </div>
            </form>
        </div>
        <div class="box">
            <div class="box-header with-border">
                <h3 class="box-title">Per-server NAT tab</h3>
            </div>
            <div class="box-body">
                <p>Open any server in the admin panel (<code>/admin/servers/view/{id}</code>). A <strong>Network / NAT</strong> tab appears in the server navigation for root administrators.</p>
                <p>Server NAT page: <code>/extensions/portforward/admin/servers/view/{serverId}</code></p>
            </div>
        </div>
    </div>
</div>
@endsection
