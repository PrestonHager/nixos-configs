{ config, pkgs, ... }:

let
  panelRoot = "/pterodactyl/html";

  configurePhp = pkgs.writeText "configure-production-extensions.php" ''
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

  configureScript = pkgs.writeShellScript "pterodactyl-blueprint-extensions-configure" ''
    set -euo pipefail

    if ! ${pkgs.podman}/bin/podman container exists pterodactyl; then
      echo "pterodactyl-blueprint-extensions-configure: panel container missing, skipping"
      exit 0
    fi

    if [ ! -d ${panelRoot}/.blueprint/extensions/portforward ]; then
      echo "pterodactyl-blueprint-extensions-configure: portforward extension missing, skipping"
      exit 0
    fi

    portforward_dry_run=1
    if [ -f /pterodactyl/secrets/pterodactyl-router-ssh-key ]; then
      portforward_dry_run=0
    fi

    ${pkgs.coreutils}/bin/cp ${configurePhp} ${panelRoot}/configure-production-extensions.php
    ${pkgs.coreutils}/bin/chown pterodactyl:pterodactyl ${panelRoot}/configure-production-extensions.php
    ${pkgs.podman}/bin/podman exec \
      -e PORTFORWARD_DRY_RUN="$portforward_dry_run" \
      pterodactyl \
      php /var/www/pterodactyl/configure-production-extensions.php
    ${pkgs.coreutils}/bin/rm -f ${panelRoot}/configure-production-extensions.php

    echo "pterodactyl-blueprint-extensions-configure: homelab defaults applied (portforward dry_run=$portforward_dry_run)"
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
    path = [ pkgs.podman pkgs.php83 pkgs.coreutils ];
  };
}
