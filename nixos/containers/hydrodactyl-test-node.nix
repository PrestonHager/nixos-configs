# Throwaway Wings node for the Hydrodactyl test panel, on ace.
#
#   homelab.panel.test.wingsNode.enable = true;
#
# Lets test.panel exercise console, files, power, backups and the Minecraft
# page without ever being able to reach the production nodes (it cannot
# decrypt their tokens, see hydrodactyl.nix). Layout:
#
#   - Docker: a docker:dind container (ace runs podman; Wings needs Docker).
#     Everything Wings hands to Docker lives under /var/lib/wings-test, mounted
#     at the same path in dind so bind mounts resolve.
#   - Wings 1.13.4 (same package as crux/elara) as a host service on
#     127.0.0.1:8080, plain HTTP.
#   - Caddy routes Wings' paths (/api/servers, /api/system, /download, ...) on
#     test.panel.prestonhager.com to it, so the node's FQDN is the panel's own
#     host: no DNS record, certificate or firewall port. Panel routes never
#     use those paths. The panel container reaches it via the pod's
#     test.panel -> host-gateway mapping (pterodactyl-test.nix).
#   - Game ports are only bound inside dind: servers here are not reachable
#     by players, which is fine for a test node.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.homelab.panel.test.wingsNode;
  caddyLib = import ../caddy/lib.nix;
  wings = inputs.pterodactyl-wings.packages.x86_64-linux.wings;

  root = "/var/lib/wings-test";
  socket = "${root}/run/docker.sock";
  host = "test.panel.prestonhager.com";
  nodeName = "ace-test";

  # Idempotently registers location/node/allocations in the test panel and
  # prints the node's id, uuid and decrypted daemon token for config.yml.
  registerPhp = pkgs.writeText "wings-test-register.php" ''
    <?php
    require "/var/www/pterodactyl/vendor/autoload.php";
    $app = require "/var/www/pterodactyl/bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

    use Pterodactyl\Models\Node;
    use Pterodactyl\Models\Location;
    use Pterodactyl\Models\Allocation;

    $location = Location::query()->firstOrCreate(["short" => "ace-test"], ["long" => "Throwaway test node on ace"]);
    $node = Node::query()->where("name", "${nodeName}")->first();
    if (!$node) {
      // Same path as Admin -> Nodes -> Create (uuid, encrypted token, validation).
      $node = app(Pterodactyl\Services\Nodes\NodeCreationService::class)->handle([
        "name" => "${nodeName}",
        "description" => "Throwaway Wings node on ace for the Hydrodactyl test panel (hydrodactyl-test-node.nix).",
        "location_id" => $location->id,
        "public" => true,
        "fqdn" => "${host}",
        "scheme" => "https",
        "behind_proxy" => true,
        "maintenance_mode" => false,
        "memory" => ${toString cfg.memory},
        "memory_overallocate" => 0,
        "disk" => ${toString cfg.disk},
        "disk_overallocate" => 0,
        "upload_size" => 100,
        "daemonListen" => 443,
        "daemonSFTP" => 2022,
        "daemonBase" => "${root}/volumes",
        "daemonType" => "wings",
      ]);
    }
    // Bound inside dind only, hence 0.0.0.0.
    foreach (range(${toString cfg.firstPort}, ${toString (cfg.firstPort + 9)}) as $port) {
      Allocation::query()->firstOrCreate(["node_id" => $node->id, "ip" => "0.0.0.0", "port" => $port]);
    }
    // Point the extensions' node maps for this node at ace (the defaults
    // seeded by pterodactyl-test-blueprint-extensions-configure are keyed by
    // the production node ids, so id 4 would mean zenith).
    use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models\DnsExtensionSetting;
    use Pterodactyl\BlueprintFramework\Extensions\portforward\Models\PortForwardSetting;
    foreach ([[DnsExtensionSetting::class, "node_fqdn_map", "${host}"], [PortForwardSetting::class, "node_ip_map", "192.168.5.5"]] as [$model, $key, $value]) {
      $map = (array) ($model::query()->where("key", $key)->first()?->value ?? []);
      $map[(string) $node->id] = $value;
      $model::query()->updateOrCreate(["key" => $key], ["value" => $map]);
    }
    echo json_encode(["id" => $node->id, "uuid" => $node->uuid, "token_id" => $node->daemon_token_id, "token" => $node->getDecryptedKey()]), "\n";
  '';

  configScript = pkgs.writeShellScript "wings-test-config" ''
    set -euo pipefail
    umask 077
    for _ in $(seq 1 120); do
      podman exec pterodactyl-test test -f /var/www/pterodactyl/.hydrodactyl-build && break
      sleep 5
    done
    json=$(podman exec -i pterodactyl-test php < ${registerPhp} | tail -n1)
    get() { printf '%s' "$json" | ${pkgs.jq}/bin/jq -r ".$1"; }
    cat > ${root}/config.yml.tmp <<EOF
    debug: false
    uuid: $(get uuid)
    token_id: $(get token_id)
    token: $(get token)
    api:
      host: 127.0.0.1
      port: 8080
      ssl:
        enabled: false
      upload_limit: 100
      trusted_proxies: ["127.0.0.1"]
    system:
      root_directory: ${root}
      log_directory: ${root}/logs
      data: ${root}/volumes
      archive_directory: ${root}/archives
      backup_directory: ${root}/backups
      tmp_directory: ${root}/tmp
      # Bind-mounted into game containers, so they must be visible to dind
      # (the defaults live under /run/wings on the host).
      machine_id:
        enabled: true
        directory: ${root}/machine-id
      passwd:
        enabled: false
        directory: ${root}/etc
      username: pterodactyl
      timezone: UTC
      sftp:
        bind_address: 127.0.0.1
        bind_port: 2022
    docker:
      network:
        interface: 172.18.0.1
        name: pterodactyl_nw
        network_mode: pterodactyl_nw
        interfaces:
          v4:
            subnet: 172.18.0.0/16
            gateway: 172.18.0.1
    allowed_origins:
      - https://${host}
    remote: https://${host}
    EOF
    mv ${root}/config.yml.tmp ${root}/config.yml
  '';

  wingsRoutes = ''
    # Wings test node (hydrodactyl-test-node.nix). Also open to the podman
    # range, but only for these paths: the panel container calls Wings here,
    # and every Wings endpoint needs its own token.
    @wings_test {
      path /api/servers /api/servers/* /api/system /api/system/* /api/update /api/transfers /api/transfers/* /api/deauthorize-user /download/* /upload/*
      remote_ip ${caddyLib.lanRangesStr} 10.88.0.0/16
    }
    handle @wings_test {
      reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
      }
    }
  '';
in
{
  options.homelab.panel.test.wingsNode = {
    enable = lib.mkEnableOption "a throwaway Wings node on ace for the Hydrodactyl test panel";
    memory = lib.mkOption { type = lib.types.int; default = 8192; description = "Node memory (MiB) offered to the test panel."; };
    disk = lib.mkOption { type = lib.types.int; default = 51200; description = "Node disk (MiB) offered to the test panel."; };
    firstPort = lib.mkOption { type = lib.types.port; default = 25600; description = "First of ten allocations (bound inside dind only)."; };
  };

  config = lib.mkIf (cfg.enable && config.homelab.panel.test.flavor == "hydrodactyl") {
    systemd.tmpfiles.rules = map (d: "d ${root}/${d} 0750 root root -") [ "" "run" "docker" "volumes" "archives" "backups" "tmp" "logs" "machine-id" "etc" ];

    virtualisation.oci-containers.containers.wings-test-docker = {
      autoStart = true;
      image = "docker.io/library/docker@sha256:bfb73322f4302ed5d380fcba01957ba871458a32245d0862758b08e0fe7916d4"; # docker 28.5.1-dind
      cmd = [ "dockerd" "--host=unix://${socket}" "--data-root=/var/lib/docker" ];
      volumes = [
        "${root}:${root}"
        "${root}/docker:/var/lib/docker"
      ];
      extraOptions = [ "--privileged" "--memory=${toString (cfg.memory + 1024)}m" ];
    };

    systemd.services.wings-test-config = {
      description = "Register the Wings test node in the test panel and write its config";
      after = [ "podman-pterodactyl-test.service" "hydrodactyl-test-configure.service" "pterodactyl-test-blueprint-extensions-configure.service" ];
      # Wants, not Requires: a panel redeploy must not bounce Wings.
      wants = [ "podman-pterodactyl-test.service" ];
      before = [ "wings-test.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.podman pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = configScript; TimeoutStartSec = "15min"; };
    };

    systemd.services.wings-test = {
      description = "Wings test node for the Hydrodactyl test panel";
      after = [ "podman-wings-test-docker.service" "wings-test-config.service" ];
      requires = [ "podman-wings-test-docker.service" ];
      wants = [ "wings-test-config.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.DOCKER_HOST = "unix://${socket}";
      path = [ pkgs.shadow pkgs.coreutils ];
      serviceConfig = {
        # Wait for dind's socket before Wings checks Docker.
        ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 60); do [ -S ${socket} ] && exit 0; sleep 1; done; exit 1'";
        ExecStart = "${wings}/bin/wings --config ${root}/config.yml";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    services.caddy.virtualHosts.${host}.extraConfig = lib.mkBefore wingsRoutes;
  };
}
