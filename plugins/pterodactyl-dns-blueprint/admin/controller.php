<?php

namespace Pterodactyl\Http\Controllers\Admin\Extensions\dnsrecords;

use Illuminate\Contracts\View\Factory as ViewFactory;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Libraries\ExtensionLibrary\Admin\BlueprintAdminLibrary as BlueprintExtensionLibrary;

class dnsrecordsExtensionController extends Controller
{
    public function __construct(
        private ViewFactory $view,
        private BlueprintExtensionLibrary $blueprint,
    ) {
    }

    public function index(): View
    {
        $context = PluginContext::make();

        return $this->view->make('admin.extensions.dnsrecords.index', [
            'root' => '/admin/extensions/dnsrecords',
            'blueprint' => $this->blueprint,
            'settings' => $context->config()->all(),
            'defaults' => $this->defaultSettings(),
        ]);
    }

    public function update(Request $request): RedirectResponse
    {
        $validated = $request->validate([
            'cloudflare_api_token' => 'nullable|string',
            'zone_id' => 'required|string',
            'base_domain' => 'required|string',
            'auto_provision_enabled' => 'nullable|boolean',
            'default_ttl' => 'nullable|integer|min:1',
            'subdomain_generation' => 'nullable|string',
            'client_subdomain_policy' => 'nullable|string',
            'client_change_limit' => 'nullable|integer|min:0',
            'client_change_period_hours' => 'nullable|integer|min:1',
            'min_label_length' => 'nullable|integer|min:1',
            'max_label_length' => 'nullable|integer|min:3',
            'allow_custom_domain' => 'nullable|boolean',
            'custom_domain_mode' => 'nullable|string',
            'srv_profiles_json' => 'nullable|string',
            'primary_domains_json' => 'nullable|string',
            'reserved_labels_json' => 'nullable|string',
        ]);

        $context = PluginContext::make();
        $existing = $context->config()->all();

        $settings = array_merge($this->defaultSettings(), $existing, [
            'zone_id' => $validated['zone_id'],
            'base_domain' => $validated['base_domain'],
            'auto_provision_enabled' => $request->boolean('auto_provision_enabled'),
            'default_ttl' => (int) ($validated['default_ttl'] ?? 1),
            'subdomain_generation' => $validated['subdomain_generation'] ?? 'server_slug',
            'client_subdomain_policy' => $validated['client_subdomain_policy'] ?? 'never',
            'client_change_limit' => (int) ($validated['client_change_limit'] ?? 1),
            'client_change_period_hours' => (int) ($validated['client_change_period_hours'] ?? 168),
            'min_label_length' => (int) ($validated['min_label_length'] ?? 3),
            'max_label_length' => (int) ($validated['max_label_length'] ?? 32),
            'allow_custom_domain' => $request->boolean('allow_custom_domain'),
            'custom_domain_mode' => $validated['custom_domain_mode'] ?? 'cname',
        ]);

        if (!empty($validated['cloudflare_api_token'])) {
            $settings['cloudflare_api_token'] = $validated['cloudflare_api_token'];
        }

        foreach (['srv_profiles_json' => 'srv_profiles', 'primary_domains_json' => 'primary_domains', 'reserved_labels_json' => 'reserved_labels'] as $input => $key) {
            if (!empty($validated[$input])) {
                $decoded = json_decode($validated[$input], true);
                if (json_last_error() === JSON_ERROR_NONE && is_array($decoded)) {
                    $settings[$key] = $decoded;
                }
            }
        }

        $context->config()->replace($settings);

        $this->blueprint->notify('DNS Records settings saved.');

        return redirect()->back();
    }

    /**
     * @return array<string, mixed>
     */
    private function defaultSettings(): array
    {
        return [
            'cloudflare_api_token' => '',
            'zone_id' => '',
            'base_domain' => '',
            'auto_provision_enabled' => true,
            'default_ttl' => 1,
            'srv_profiles' => [],
            'primary_domains' => [],
            'subdomain_generation' => 'server_slug',
            'client_subdomain_policy' => 'never',
            'client_change_limit' => 1,
            'client_change_period_hours' => 168,
            'reserved_labels' => [],
            'min_label_length' => 3,
            'max_label_length' => 32,
            'allow_custom_domain' => false,
            'custom_domain_mode' => 'cname',
        ];
    }
}
