<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Ssh;

use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\Config;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;
use Symfony\Component\Process\Process;

class SshClient
{
    public function __construct(
        private readonly Config $config,
    ) {
    }

    /**
     * @param string[] $commands
     * @return array{stdout: string, stderr: string, exitCode: int}
     */
    public function exec(array $commands): array
    {
        if ($this->config->dryRun()) {
            return [
                'stdout' => "DRY-RUN: would execute:\n" . implode("\n", $commands),
                'stderr' => '',
                'exitCode' => 0,
            ];
        }

        $keyPath = $this->config->sshKeyPath();
        if ($keyPath === '') {
            throw new PluginException('Router SSH private key is not configured.');
        }

        $remoteScript = implode("\n", $commands);
        $sshConfig = $this->config->sshConfigPath();
        $base = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new'];
        if ($sshConfig !== '') {
            $base[] = '-F';
            $base[] = $sshConfig;
        } else {
            $base[] = '-i';
            $base[] = $keyPath;
            $base[] = '-o';
            $base[] = 'KexAlgorithms=+diffie-hellman-group14-sha1';
            $base[] = '-o';
            $base[] = 'HostKeyAlgorithms=+ssh-rsa';
            $base[] = '-o';
            $base[] = 'PubkeyAcceptedAlgorithms=+ssh-rsa';
        }

        $base[] = sprintf('%s@%s', $this->config->routerSshUser(), $this->config->routerHost());
        $base[] = $remoteScript;

        $process = new Process($base, timeout: 60);
        $process->run();

        return [
            'stdout' => $process->getOutput(),
            'stderr' => $process->getErrorOutput(),
            'exitCode' => $process->getExitCode() ?? 1,
        ];
    }

    public function testConnection(): array
    {
        return $this->exec(['show ip interface brief']);
    }
}
