<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;

class Config
{
    public function __construct(
        private readonly PluginContext $context,
    ) {
    }

    public function enabled(): bool
    {
        return filter_var($this->context->config()->get('enabled', false), FILTER_VALIDATE_BOOLEAN);
    }

    public function routerHost(): string
    {
        return (string) $this->context->config()->get('router_host', '192.168.5.1');
    }

    public function routerSshUser(): string
    {
        return (string) $this->context->config()->get('router_ssh_user', 'pterofwd');
    }

    public function wanInterface(): string
    {
        return (string) $this->context->config()->get('wan_interface', 'GigabitEthernet0/0');
    }

    public function dryRun(): bool
    {
        return filter_var($this->context->config()->get('dry_run', true), FILTER_VALIDATE_BOOLEAN);
    }

    public function autoForwardOnInstall(): bool
    {
        return filter_var($this->context->config()->get('auto_forward_on_install', false), FILTER_VALIDATE_BOOLEAN);
    }

    public function autoRemoveOnDelete(): bool
    {
        return filter_var($this->context->config()->get('auto_remove_on_delete', true), FILTER_VALIDATE_BOOLEAN);
    }

    public function allowedPortMin(): int
    {
        return max(1, (int) $this->context->config()->get('allowed_port_min', 1024));
    }

    public function allowedPortMax(): int
    {
        return min(65535, (int) $this->context->config()->get('allowed_port_max', 65535));
    }

    public function maxMappingsPerServer(): int
    {
        return max(1, (int) $this->context->config()->get('max_mappings_per_server', 8));
    }

    /**
     * @return int[]
     */
    public function blockedPorts(): array
    {
        $raw = $this->context->config()->get('blocked_ports', [22, 80, 443, 3380]);

        return is_array($raw) ? array_map('intval', $raw) : [22, 80, 443, 3380];
    }

    /**
     * @return array<string, string>
     */
    public function nodeIpMap(): array
    {
        $raw = $this->context->config()->get('node_ip_map', []);
        if (!is_array($raw) || $raw === []) {
            return [
                'default_crux' => '192.168.5.6',
                'default_nova' => '192.168.5.7',
            ];
        }

        $map = [];
        foreach ($raw as $key => $value) {
            if (is_array($value) && isset($value['node_id'], $value['ip'])) {
                $map[(string) $value['node_id']] = (string) $value['ip'];
            } elseif (is_string($key) && (is_string($value) || is_numeric($value))) {
                $map[(string) $key] = (string) $value;
            }
        }

        return $map;
    }

    public function sshKeyPath(): string
    {
        $file = getenv('PORTFORWARD_SSH_KEY_FILE') ?: '';
        if ($file !== '' && is_readable($file)) {
            return $file;
        }

        $configured = $this->context->config()->get('router_ssh_key_file', '');
        if (is_string($configured) && $configured !== '' && is_readable($configured)) {
            return $configured;
        }

        $inline = $this->context->config()->get('router_ssh_private_key', '');
        if (is_string($inline) && str_contains($inline, 'BEGIN')) {
            $tmp = sys_get_temp_dir() . '/pterodactyl-portforward-key';
            if (!is_file($tmp)) {
                file_put_contents($tmp, $inline);
                chmod($tmp, 0600);
            }

            return $tmp;
        }

        return '';
    }

    public function sshConfigPath(): string
    {
        $file = getenv('PORTFORWARD_SSH_CONFIG_FILE') ?: '';

        return is_string($file) && $file !== '' && is_readable($file) ? $file : '';
    }
}
