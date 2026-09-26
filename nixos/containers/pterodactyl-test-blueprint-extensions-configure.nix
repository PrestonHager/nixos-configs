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

    function dnsDefault(string $key, mixed $value): void {
      DnsExtensionSetting::query()->firstOrCreate(["key" => $key], ["value" => $value]);
    }

    function resolveCloudflareZoneId(): string {
      $token = getenv("CLOUDFLARE_API_TOKEN") ?: "";
      $tokenFile = getenv("CLOUDFLARE_API_TOKEN_FILE") ?: "";
      if ($tokenFile !== "" && is_readable($tokenFile)) {
        $token = trim((string) file_get_contents($tokenFile));
      }
      if ($token === "") {
        return "";
      }
      $ctx = stream_context_create([
        "http" => [
          "header" => "Authorization: Bearer {$token}\r\nAccept: application/json\r\n",
          "timeout" => 15,
        ],
      ]);
      $body = @file_get_contents("https://api.cloudflare.com/client/v4/zones?name=prestonhager.com", false, $ctx);
      if ($body === false) {
        return "";
      }
      $json = json_decode($body, true);
      if (!is_array($json) || !isset($json["result"][0]["id"])) {
        return "";
      }
      return (string) $json["result"][0]["id"];
    }

    $dryRun = getenv("PORTFORWARD_DRY_RUN") !== "0";

    $portforward = [
      "enabled" => true,
      "router_host" => "192.168.5.1",
      "router_ssh_user" => "pterofwd",
      "ssh_connect_host" => "astracap",
      "ssh_kex_algorithms" => "+diffie-hellman-group14-sha1",
      "ssh_host_key_algorithms" => "+ssh-rsa",
      "ssh_pubkey_accepted_algorithms" => "+ssh-rsa",
      "ssh_ciphers" => "",
      "ssh_config_file" => "",
      "ssh_config_content" => "",
      "ssh_extra_options" => "",
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
      "dns_provider_mode" => "both",
      "base_domain" => "prestonhager.com",
      "technitium_api_url" => "http://host.containers.internal:5380",
      "technitium_default_zone" => "prestonhager.com",
      "dry_run" => false,
      "auto_provision_enabled" => true,
      "update_on_allocation_change" => true,
    ];
    foreach ($dns as $key => $value) {
      dnsDefault($key, $value);
    }

    $srvProfiles = [
      ["id" => "minecraft-java", "preset" => "minecraft-java", "label" => "Minecraft Java", "auto_provision" => true],
      ["id" => "minecraft-bedrock", "preset" => "minecraft-bedrock", "label" => "Minecraft Bedrock", "auto_provision" => false],
      ["id" => "factorio", "preset" => "factorio", "label" => "Factorio", "auto_provision" => true],
      ["id" => "terraria", "preset" => "terraria", "label" => "Terraria", "auto_provision" => false],
      ["id" => "valheim", "preset" => "valheim", "label" => "Valheim", "auto_provision" => false],
      ["id" => "rust", "preset" => "rust", "label" => "Rust", "auto_provision" => false],
      ["id" => "generic-tcp", "label" => "Generic TCP", "service" => "_game", "proto" => "_tcp", "priority" => 0, "weight" => 5, "auto_provision" => false],
      ["id" => "generic-udp", "label" => "Generic UDP", "service" => "_game", "proto" => "_udp", "priority" => 0, "weight" => 5, "auto_provision" => false],
    ];
    dnsDefault("srv_profiles", $srvProfiles);
    dnsDefault("primary_domains", []);
    dnsDefault("node_fqdn_map", [
      "1" => "crux.lc1.nm.us.prestonhager.com",
      "2" => "nova.lc1.nm.us.prestonhager.com",
      "default_crux" => "crux.lc1.nm.us.prestonhager.com",
      "default_nova" => "nova.lc1.nm.us.prestonhager.com",
    ]);

    $zoneId = resolveCloudflareZoneId();
    if ($zoneId !== "") {
      $existingZone = DnsExtensionSetting::query()->where("key", "zone_id")->value("value");
      $existingZoneStr = is_string($existingZone) ? trim($existingZone) : "";
      if ($existingZoneStr === "" || str_contains($existingZoneStr, ".")) {
        DnsExtensionSetting::query()->updateOrCreate(["key" => "zone_id"], ["value" => $zoneId]);
      } else {
        dnsDefault("zone_id", $zoneId);
      }
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

    ${pkgs.coreutils}/bin/cp ${configurePhp} ${testPanelDir}/configure-test-extensions.php
    ${pkgs.coreutils}/bin/chown prestonh:users ${testPanelDir}/configure-test-extensions.php
    ${pkgs.podman}/bin/podman exec \
      -e PORTFORWARD_DRY_RUN="$portforward_dry_run" \
      pterodactyl-test \
      php /var/www/pterodactyl/configure-test-extensions.php
    ${pkgs.coreutils}/bin/rm -f ${testPanelDir}/configure-test-extensions.php

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
