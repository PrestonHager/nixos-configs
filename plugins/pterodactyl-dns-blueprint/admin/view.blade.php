@extends('layouts.admin')

@section('title')
    DNS Records
@endsection

@section('content-header')
    <h1>DNS Records<small>Cloudflare DNS management for game servers</small></h1>
    <ol class="breadcrumb">
        <li><a href="{{ route('admin.index') }}">Admin</a></li>
        <li class="active">Extensions</li>
        <li class="active">DNS Records</li>
    </ol>
@endsection

@section('content')
<div class="row">
    <div class="col-xs-12">
        <div class="box">
            <div class="box-header with-border">
                <h3 class="box-title">DNS configuration</h3>
            </div>
            <form action="{{ $root }}" method="POST">
                @csrf
                @method('PATCH')
                <div class="box-body">
                    <div class="form-group">
                        <label for="dns_provider_mode">Provider mode</label>
                        <select class="form-control" id="dns_provider_mode" name="dns_provider_mode">
                            @foreach (['cloudflare' => 'Cloudflare only', 'technitium' => 'Technitium only', 'both' => 'Both (Cloudflare + Technitium)'] as $value => $label)
                                <option value="{{ $value }}" @selected(old('dns_provider_mode', $settings['dns_provider_mode'] ?? 'cloudflare') === $value)>{{ $label }}</option>
                            @endforeach
                        </select>
                    </div>
                    <div class="form-group">
                        <label for="cloudflare_api_token">Cloudflare API token</label>
                        <input type="password" class="form-control" id="cloudflare_api_token" name="cloudflare_api_token" placeholder="Leave blank to keep existing token or use CLOUDFLARE_API_TOKEN_FILE">
                        <p class="help-block">Requires Zone.DNS Edit and Zone.Zone Read scopes. On ace, the same token as Caddy DNS-01 is mounted via sops (<code>CLOUDFLARE_API_TOKEN_FILE</code>).</p>
                    </div>
                    <div class="form-group">
                        <label for="zone_id">Default zone ID</label>
                        <input type="text" class="form-control" id="zone_id" name="zone_id" value="{{ old('zone_id', $settings['zone_id'] ?? '') }}" required>
                    </div>
                    <div class="form-group">
                        <label for="base_domain">Base domain</label>
                        <input type="text" class="form-control" id="base_domain" name="base_domain" value="{{ old('base_domain', $settings['base_domain'] ?? '') }}" required>
                    </div>
                    <div class="form-group">
                        <label for="technitium_api_url">Technitium API URL</label>
                        <input type="text" class="form-control" id="technitium_api_url" name="technitium_api_url" value="{{ old('technitium_api_url', $settings['technitium_api_url'] ?? 'http://host.containers.internal:5380') }}">
                    </div>
                    <div class="form-group">
                        <label for="technitium_api_token">Technitium API token</label>
                        <input type="password" class="form-control" id="technitium_api_token" name="technitium_api_token" placeholder="Leave blank to keep existing or use TECHNITIUM_API_TOKEN_FILE">
                    </div>
                    <div class="form-group">
                        <label for="technitium_default_zone">Technitium default zone</label>
                        <input type="text" class="form-control" id="technitium_default_zone" name="technitium_default_zone" value="{{ old('technitium_default_zone', $settings['technitium_default_zone'] ?? 'prestonhager.com') }}">
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="dns_dry_run" name="dry_run" value="1" @checked(old('dry_run', $settings['dry_run'] ?? false))>
                        <label for="dns_dry_run">Dry-run mode (log intended DNS changes without API calls)</label>
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="dns_update_on_allocation_change" name="update_on_allocation_change" value="1" @checked(old('update_on_allocation_change', $settings['update_on_allocation_change'] ?? true))>
                        <label for="dns_update_on_allocation_change">Update SRV records when primary allocation changes</label>
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="dns_auto_provision_enabled" name="auto_provision_enabled" value="1" @checked(old('auto_provision_enabled', $settings['auto_provision_enabled'] ?? true))>
                        <label for="dns_auto_provision_enabled">Auto-provision A + SRV records on server install</label>
                    </div>
                    <div class="form-group">
                        <label for="default_ttl">Default TTL</label>
                        <input type="number" class="form-control" id="default_ttl" name="default_ttl" min="1" value="{{ old('default_ttl', $settings['default_ttl'] ?? 1) }}">
                    </div>
                    <div class="form-group">
                        <div class="dns-help-label-row">
                            <label for="srv_profiles_json">SRV profiles (JSON)</label>
                            <button type="button" class="dns-help-btn" data-dns-help-open="srv-profiles" aria-label="Help: SRV profiles JSON">?</button>
                        </div>
                        <textarea class="form-control" id="srv_profiles_json" name="srv_profiles_json" rows="12" aria-describedby="srv_profiles_json_help">{{ old('srv_profiles_json', json_encode($settings['srv_profiles'] ?? [], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)) }}</textarea>
                        <p class="help-block" id="srv_profiles_json_help">Game/service SRV templates. Click <strong>?</strong> for full field reference and homelab defaults.</p>
                    </div>
                    <div class="form-group">
                        <div class="dns-help-label-row">
                            <label for="primary_domains_json">Primary domains (JSON)</label>
                            <button type="button" class="dns-help-btn" data-dns-help-open="primary-domains" aria-label="Help: Primary domains JSON">?</button>
                        </div>
                        <textarea class="form-control" id="primary_domains_json" name="primary_domains_json" rows="4" aria-describedby="primary_domains_json_help">{{ old('primary_domains_json', json_encode($settings['primary_domains'] ?? [], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)) }}</textarea>
                        <p class="help-block" id="primary_domains_json_help">Additional vanity hostname zones beyond the implicit default (<code>base_domain</code>). Click <strong>?</strong> for documentation.</p>
                    </div>
                    <div class="form-group">
                        <label for="client_subdomain_policy">Client subdomain policy</label>
                        <select class="form-control" id="client_subdomain_policy" name="client_subdomain_policy">
                            @foreach (['never' => 'Never (admin only)', 'once_on_create' => 'Once on create', 'limited' => 'Limited changes', 'always' => 'Always'] as $value => $label)
                                <option value="{{ $value }}" @selected(old('client_subdomain_policy', $settings['client_subdomain_policy'] ?? 'never') === $value)>{{ $label }}</option>
                            @endforeach
                        </select>
                    </div>
                    <div class="checkbox">
                        <input type="checkbox" id="dns_allow_custom_domain" name="allow_custom_domain" value="1" @checked(old('allow_custom_domain', $settings['allow_custom_domain'] ?? false))>
                        <label for="dns_allow_custom_domain">Allow custom domains (CNAME / nameserver verification)</label>
                    </div>
                </div>
                <div class="box-footer">
                    <button type="submit" class="btn btn-primary pull-right">Save settings</button>
                </div>
            </form>
        </div>
        <div class="box">
            <div class="box-header with-border">
                <h3 class="box-title">Admin server DNS tab</h3>
            </div>
            <div class="box-body">
                <p>Open any server in the admin panel (<code>/admin/servers/view/{id}</code>). A <strong>DNS</strong> tab appears in the server navigation for root administrators.</p>
                <p>Server DNS page: <code>/extensions/dnsrecords/admin/servers/view/{serverId}</code></p>
                <p>API base for the admin UI: <code>/extensions/dnsrecords/admin/servers/{serverId}/...</code></p>
            </div>
        </div>
    </div>
</div>

<link rel="stylesheet" href="/extensions/dnsrecords/admin-settings.css">
@include('admin.extensions.dnsrecords.partials.settings-help')

<div id="dns-settings-help-modal" class="dns-help-modal" role="dialog" aria-modal="true" aria-hidden="true" aria-labelledby="dns-settings-help-title">
    <div class="dns-help-modal__backdrop" tabindex="-1"></div>
    <div class="dns-help-modal__dialog">
        <div class="dns-help-modal__header">
            <h4 id="dns-settings-help-title">Settings help</h4>
            <button type="button" class="dns-help-modal__close" aria-label="Close help dialog">&times;</button>
        </div>
        <div class="dns-help-modal__body" id="dns-settings-help-body"></div>
    </div>
</div>

<script src="/extensions/dnsrecords/admin-settings.js"></script>
@endsection
