{ config, pkgs, ... }:

let
  configureScript = pkgs.writeShellScript "pterodactyl-blueprint-extensions-configure" ''
    set -euo pipefail

    if ! ${pkgs.podman}/bin/podman container exists pterodactyl; then
      echo "pterodactyl-blueprint-extensions-configure: panel container missing, skipping"
      exit 0
    fi

    if [ ! -d /pterodactyl/html/.blueprint/extensions/portforward ]; then
      echo "pterodactyl-blueprint-extensions-configure: portforward extension missing, skipping"
      exit 0
    fi

    live_nat=0
    if [ -f /pterodactyl/secrets/pterodactyl-router-ssh-key ]; then
      live_nat=1
    fi

    ${pkgs.podman}/bin/podman exec pterodactyl php /var/www/pterodactyl/artisan tinker --execute="
use Pterodactyl\\BlueprintFramework\\Extensions\\portforward\\Models\\PortForwardSetting;
use Pterodactyl\\BlueprintFramework\\Extensions\\dnsrecords\\Models\\DnsExtensionSetting;

\$portforward = [
  'enabled' => true,
  'router_host' => '192.168.5.1',
  'router_ssh_user' => 'pterofwd',
  'wan_interface' => 'GigabitEthernet0/0',
  'dry_run' => ''${live_nat} ? false : true,
  'auto_forward_on_install' => false,
  'auto_remove_on_delete' => true,
  'allowed_port_min' => 1024,
  'allowed_port_max' => 65535,
  'blocked_ports' => [22, 80, 443, 3380],
  'node_ip_map' => ['1' => '192.168.5.6', '2' => '192.168.5.7'],
  'max_mappings_per_server' => 8,
];
foreach (\$portforward as \$key => \$value) {
  PortForwardSetting::query()->updateOrCreate(['key' => \$key], ['value' => \$value]);
}

\$dns = [
  'dns_provider_mode' => 'technitium',
  'technitium_api_url' => 'http://host.containers.internal:5380',
  'technitium_default_zone' => 'prestonhager.com',
  'dry_run' => false,
  'auto_provision_enabled' => true,
];
foreach (\$dns as \$key => \$value) {
  DnsExtensionSetting::query()->updateOrCreate(['key' => \$key], ['value' => \$value]);
}
echo 'extensions configured';
" 2>/dev/null || true

    echo "pterodactyl-blueprint-extensions-configure: portforward enabled (dry_run=\$live_nat)"
  '';
in
{
  systemd.services.pterodactyl-blueprint-extensions-configure = {
    description = "Enable Blueprint dnsrecords and portforward extension defaults on production panel";
    after = [
      "pterodactyl-blueprint-install.service"
      "pterodactyl-blueprint-extensions-env.service"
      "podman-pterodactyl.service"
    ];
    wants = [
      "pterodactyl-blueprint-install.service"
      "pterodactyl-blueprint-extensions-env.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = configureScript;
      RemainAfterExit = true;
      TimeoutStartSec = "10min";
    };
    path = [ pkgs.podman pkgs.php83 ];
  };
}
