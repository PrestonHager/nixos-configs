{ config, pkgs, ... }:

let
  testPanelDir = "/home/prestonh/Projects/panel";

  configurePhp = pkgs.writeText "configure-test-extensions.php" ''
    <?php
    require "/var/www/pterodactyl/vendor/autoload.php";
    $app = require "/var/www/pterodactyl/bootstrap/app.php";
    $app->make("Illuminate\Contracts\Console\Kernel")->bootstrap();

    use Pterodactyl\BlueprintFramework\Extensions\portforward\Models\PortForwardSetting;
    use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionSetting;

    $dryRun = getenv("PORTFORWARD_DRY_RUN") !== "0";

    $portforward = [
      "enabled" => true,
      "router_host" => "192.168.5.1",
      "router_ssh_user" => "pterofwd",
      "wan_interface" => "GigabitEthernet0/0",
      "dry_run" => $dryRun,
      "auto_forward_on_install" => false,
      "auto_remove_on_delete" => true,
      "allowed_port_min" => 1024,
      "allowed_port_max" => 65535,
      "blocked_ports" => [22, 80, 443, 3380],
      "node_ip_map" => ["1" => "192.168.5.6", "2" => "192.168.5.7"],
      "max_mappings_per_server" => 8,
    ];
    foreach ($portforward as $key => $value) {
      PortForwardSetting::query()->updateOrCreate(["key" => $key], ["value" => $value]);
    }

    $dns = [
      "dns_provider_mode" => "technitium",
      "technitium_api_url" => "http://host.containers.internal:5380",
      "technitium_default_zone" => "prestonhager.com",
      "dry_run" => false,
      "auto_provision_enabled" => true,
      "update_on_allocation_change" => true,
    ];
    foreach ($dns as $key => $value) {
      DnsExtensionSetting::query()->updateOrCreate(["key" => $key], ["value" => $value]);
    }
    echo "extensions configured\n";
  '';

  configureScript = pkgs.writeShellScript "pterodactyl-test-blueprint-extensions-configure" ''
    set -euo pipefail

    if ! ${pkgs.podman}/bin/podman container exists pterodactyl-test; then
      echo "pterodactyl-test-blueprint-extensions-configure: panel container missing, skipping"
      exit 0
    fi

    if [ ! -d ${testPanelDir}/.blueprint/extensions/portforward ]; then
      echo "pterodactyl-test-blueprint-extensions-configure: portforward extension missing, skipping"
      exit 0
    fi

    portforward_dry_run=1
    if [ -f /pterodactyl/secrets/pterodactyl-router-ssh-key ]; then
      portforward_dry_run=0
    fi

    ${pkgs.coreutils}/bin/cp ${configurePhp} /tmp/configure-test-extensions.php
    ${pkgs.podman}/bin/podman cp /tmp/configure-test-extensions.php pterodactyl-test:/tmp/configure-test-extensions.php
    ${pkgs.podman}/bin/podman exec \
      -e PORTFORWARD_DRY_RUN="$portforward_dry_run" \
      pterodactyl-test \
      php /tmp/configure-test-extensions.php

    echo "pterodactyl-test-blueprint-extensions-configure: homelab defaults applied (portforward dry_run=$portforward_dry_run)"
  '';
in
{
  systemd.services.pterodactyl-test-blueprint-extensions-configure = {
    description = "Enable Blueprint dnsrecords and portforward extension defaults on test panel";
    after = [
      "pterodactyl-test-blueprint-install.service"
      "pterodactyl-blueprint-extensions-env.service"
      "podman-pterodactyl-test.service"
    ];
    wants = [
      "pterodactyl-test-blueprint-install.service"
      "pterodactyl-blueprint-extensions-env.service"
    ];
    before = [ "pterodactyl-test-sso-configure.service" ];
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
