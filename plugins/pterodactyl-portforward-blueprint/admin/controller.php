<?php

namespace Pterodactyl\Http\Controllers\Admin\Extensions\portforward;

use Illuminate\Contracts\View\Factory as ViewFactory;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Libraries\ExtensionLibrary\Admin\BlueprintAdminLibrary as BlueprintExtensionLibrary;
use Pterodactyl\Http\Controllers\Controller;

class portforwardExtensionController extends Controller
{
    public function __construct(
        private ViewFactory $view,
        private BlueprintExtensionLibrary $blueprint,
    ) {
    }

    public function index(): View
    {
        $context = PluginContext::make();

        return $this->view->make('admin.extensions.portforward.index', [
            'root' => '/admin/extensions/portforward',
            'blueprint' => $this->blueprint,
            'settings' => $context->config()->all(),
            'defaults' => $this->defaultSettings(),
        ]);
    }

    public function update(Request $request): RedirectResponse
    {
        $validated = $request->validate([
            'router_host' => 'nullable|string',
            'router_ssh_user' => 'nullable|string',
            'router_ssh_private_key' => 'nullable|string',
            'wan_interface' => 'nullable|string',
            'allowed_port_min' => 'nullable|integer|min:1',
            'allowed_port_max' => 'nullable|integer|min:1',
            'max_mappings_per_server' => 'nullable|integer|min:1',
            'node_ip_map_json' => 'nullable|string',
            'blocked_ports_json' => 'nullable|string',
        ]);

        $context = PluginContext::make();
        $existing = $context->config()->all();

        $settings = array_merge($this->defaultSettings(), $existing, [
            'enabled' => $request->boolean('enabled'),
            'dry_run' => $request->boolean('dry_run'),
            'auto_forward_on_install' => $request->boolean('auto_forward_on_install'),
            'auto_remove_on_delete' => $request->boolean('auto_remove_on_delete'),
            'router_host' => $validated['router_host'] ?? '192.168.5.1',
            'router_ssh_user' => $validated['router_ssh_user'] ?? 'prestonh',
            'wan_interface' => $validated['wan_interface'] ?? 'GigabitEthernet0/0',
            'allowed_port_min' => (int) ($validated['allowed_port_min'] ?? 1024),
            'allowed_port_max' => (int) ($validated['allowed_port_max'] ?? 65535),
            'max_mappings_per_server' => (int) ($validated['max_mappings_per_server'] ?? 8),
        ]);

        if (!empty($validated['router_ssh_private_key'])) {
            $settings['router_ssh_private_key'] = $validated['router_ssh_private_key'];
        }

        foreach (['node_ip_map_json' => 'node_ip_map', 'blocked_ports_json' => 'blocked_ports'] as $input => $key) {
            if (!empty($validated[$input])) {
                $decoded = json_decode($validated[$input], true);
                if (json_last_error() === JSON_ERROR_NONE && is_array($decoded)) {
                    $settings[$key] = $decoded;
                }
            }
        }

        $context->config()->replace($settings);
        $this->blueprint->notify('Port Forward settings saved.');

        return redirect()->back();
    }

    /**
     * @return array<string, mixed>
     */
    private function defaultSettings(): array
    {
        return [
            'enabled' => false,
            'router_host' => '192.168.5.1',
            'router_ssh_user' => 'prestonh',
            'router_ssh_private_key' => '',
            'wan_interface' => 'GigabitEthernet0/0',
            'dry_run' => true,
            'auto_forward_on_install' => false,
            'auto_remove_on_delete' => true,
            'allowed_port_min' => 1024,
            'allowed_port_max' => 65535,
            'blocked_ports' => [22, 80, 443, 3380],
            'node_ip_map' => [],
            'max_mappings_per_server' => 8,
        ];
    }
}
