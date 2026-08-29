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
            return self::defaultNodeIpMap();
        }

        $map = [];
        foreach ($raw as $key => $value) {
            if (is_array($value) && isset($value['node_id'], $value['ip'])) {
                $map[(string) $value['node_id']] = (string) $value['ip'];
            } elseif ((is_string($key) || is_int($key)) && (is_string($value) || is_numeric($value))) {
                // json_decode turns numeric-string keys like {"1": "..."} into ints;
                // coerce back so node-ID lookups survive a decode/encode round-trip.
                $map[(string) $key] = (string) $value;
            }
        }

        return $map === [] ? self::defaultNodeIpMap() : $map;
    }

    /**
     * @return array<string, string>
     */
    public static function defaultNodeIpMap(): array
    {
        return [
            '1' => '192.168.5.6',
            '2' => '192.168.5.7',
            '3' => '192.168.5.8',
            '4' => '192.168.5.9',
            'default_crux' => '192.168.5.6',
            'default_nova' => '192.168.5.7',
            'default_elara' => '192.168.5.8',
            'default_zenith' => '192.168.5.9',
        ];
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
        if ($file !== '' && is_readable($file)) {
            return $file;
        }

        $configured = $this->context->config()->get('ssh_config_file', '');
        if (is_string($configured) && $configured !== '' && is_readable($configured)) {
            return $configured;
        }

        $inline = $this->context->config()->get('ssh_config_content', '');
        if (is_string($inline) && trim($inline) !== '') {
            $tmp = sys_get_temp_dir() . '/pterodactyl-portforward-ssh-config';
            if (!is_file($tmp) || file_get_contents($tmp) !== $inline) {
                file_put_contents($tmp, $inline);
                chmod($tmp, 0600);
            }

            return $tmp;
        }

        return '';
    }

    public function sshKexAlgorithms(): string
    {
        return (string) $this->context->config()->get(
            'ssh_kex_algorithms',
            '+diffie-hellman-group14-sha1',
        );
    }

    public function sshHostKeyAlgorithms(): string
    {
        return (string) $this->context->config()->get('ssh_host_key_algorithms', '+ssh-rsa');
    }

    public function sshPubkeyAcceptedAlgorithms(): string
    {
        return (string) $this->context->config()->get('ssh_pubkey_accepted_algorithms', '+ssh-rsa');
    }

    public function sshCiphers(): string
    {
        return (string) $this->context->config()->get('ssh_ciphers', '');
    }

    /**
     * Hostname or alias passed to ssh(1). When a drop-in config defines Host astracap,
     * use that alias so legacy KEX/HostKey options apply.
     *
     * @return string[]
     */
    public function sshOptions(): array
    {
        $options = [];

        if ($kex = trim($this->sshKexAlgorithms())) {
            $options[] = 'KexAlgorithms=' . $kex;
        }
        if ($hostKey = trim($this->sshHostKeyAlgorithms())) {
            $options[] = 'HostKeyAlgorithms=' . $hostKey;
        }
        if ($pubkey = trim($this->sshPubkeyAcceptedAlgorithms())) {
            $options[] = 'PubkeyAcceptedAlgorithms=' . $pubkey;
        }
        if ($ciphers = trim($this->sshCiphers())) {
            $options[] = 'Ciphers=' . $ciphers;
        }

        $extra = $this->context->config()->get('ssh_extra_options', '');
        if (is_string($extra) && trim($extra) !== '') {
            foreach (preg_split('/\R/', trim($extra)) as $line) {
                $line = trim($line);
                if ($line === '' || str_starts_with($line, '#')) {
                    continue;
                }
                if (str_starts_with($line, '-o ')) {
                    $line = substr($line, 3);
                }
                $options[] = $line;
            }
        }

        return $options;
    }

    public function sshConnectHost(): string
    {
        $configured = $this->context->config()->get('ssh_connect_host', '');
        if (is_string($configured) && trim($configured) !== '') {
            return trim($configured);
        }

        return $this->routerHost();
    }
}
