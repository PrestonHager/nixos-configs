<?php

namespace Pterodactyl\Addons\PortForward;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;

/**
 * JSON replacement for the Blueprint port-forward settings page. Same keys
 * and defaults; the router private key is write-only.
 */
class PortForwardSettingsController extends Controller
{
    public function show(): JsonResponse
    {
        $settings = array_merge($this->defaults(), PluginContext::make()->config()->all());
        $settings['router_ssh_private_key_set'] = !empty($settings['router_ssh_private_key']);
        unset($settings['router_ssh_private_key']);

        // Prod reads the key from PORTFORWARD_SSH_KEY_FILE (sops) instead.
        $settings['ssh_key_file_configured'] = (getenv('PORTFORWARD_SSH_KEY_FILE') ?: '') !== '';

        return response()->json(['settings' => $settings]);
    }

    public function update(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'enabled' => 'boolean',
            'dry_run' => 'boolean',
            'auto_forward_on_install' => 'boolean',
            'auto_remove_on_delete' => 'boolean',
            'router_host' => 'nullable|string',
            'router_ssh_user' => 'nullable|string',
            'router_ssh_private_key' => 'nullable|string',
            'ssh_connect_host' => 'nullable|string',
            'ssh_kex_algorithms' => 'nullable|string',
            'ssh_host_key_algorithms' => 'nullable|string',
            'ssh_pubkey_accepted_algorithms' => 'nullable|string',
            'ssh_ciphers' => 'nullable|string',
            'ssh_config_file' => 'nullable|string',
            'ssh_config_content' => 'nullable|string',
            'ssh_extra_options' => 'nullable|string',
            'wan_interface' => 'nullable|string',
            'allowed_port_min' => 'nullable|integer|min:1|max:65535',
            'allowed_port_max' => 'nullable|integer|min:1|max:65535',
            'max_mappings_per_server' => 'nullable|integer|min:1',
            'blocked_ports' => 'nullable|array',
            'blocked_ports.*' => 'integer|min:1|max:65535',
            'node_ip_map' => 'nullable|array',
            'node_ip_map.*' => 'ip',
        ]);

        $context = PluginContext::make();
        $settings = array_merge($this->defaults(), $context->config()->all(), [
            'enabled' => $request->boolean('enabled'),
            'dry_run' => $request->boolean('dry_run'),
            'auto_forward_on_install' => $request->boolean('auto_forward_on_install'),
            'auto_remove_on_delete' => $request->boolean('auto_remove_on_delete'),
            'router_host' => $validated['router_host'] ?? '192.168.5.1',
            'router_ssh_user' => $validated['router_ssh_user'] ?? 'pterofwd',
            'ssh_connect_host' => $validated['ssh_connect_host'] ?? 'astracap',
            'ssh_kex_algorithms' => $validated['ssh_kex_algorithms'] ?? '+diffie-hellman-group14-sha1',
            'ssh_host_key_algorithms' => $validated['ssh_host_key_algorithms'] ?? '+ssh-rsa',
            'ssh_pubkey_accepted_algorithms' => $validated['ssh_pubkey_accepted_algorithms'] ?? '+ssh-rsa',
            'ssh_ciphers' => $validated['ssh_ciphers'] ?? '',
            'ssh_config_file' => $validated['ssh_config_file'] ?? '',
            'ssh_config_content' => $validated['ssh_config_content'] ?? '',
            'ssh_extra_options' => $validated['ssh_extra_options'] ?? '',
            'wan_interface' => $validated['wan_interface'] ?? 'GigabitEthernet0/0',
            'allowed_port_min' => (int) ($validated['allowed_port_min'] ?? 1024),
            'allowed_port_max' => (int) ($validated['allowed_port_max'] ?? 65535),
            'max_mappings_per_server' => (int) ($validated['max_mappings_per_server'] ?? 8),
        ]);

        if (!empty($validated['router_ssh_private_key'])) {
            $settings['router_ssh_private_key'] = $validated['router_ssh_private_key'];
        }
        if (isset($validated['blocked_ports'])) {
            $settings['blocked_ports'] = array_values(array_map('intval', $validated['blocked_ports']));
        }
        if (isset($validated['node_ip_map'])) {
            $settings['node_ip_map'] = array_map('strval', $validated['node_ip_map']);
        }

        $context->config()->replace($settings);

        return $this->show();
    }

    /**
     * @return array<string, mixed>
     */
    private function defaults(): array
    {
        return [
            'enabled' => false,
            'router_host' => '192.168.5.1',
            'router_ssh_user' => 'pterofwd',
            'ssh_connect_host' => 'astracap',
            'ssh_kex_algorithms' => '+diffie-hellman-group14-sha1',
            'ssh_host_key_algorithms' => '+ssh-rsa',
            'ssh_pubkey_accepted_algorithms' => '+ssh-rsa',
            'ssh_ciphers' => '',
            'ssh_config_file' => '',
            'ssh_config_content' => '',
            'ssh_extra_options' => '',
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
