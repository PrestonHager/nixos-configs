# Test host reproducing ace's podman patterns (see tests/podman-upgrade/default.nix).
# `images` is built from one fixed nixpkgs so old and new systems share image IDs.
images:
{ config, lib, pkgs, ... }:
let
  podman = "${pkgs.podman}/bin/podman";
  tbox = { image = "localhost/tbox:1"; imageFile = images.tbox; };
  postgres = { image = "docker.io/library/postgres:16-alpine"; imageFile = images.postgres; };

  # Same shape as zitadel.nix / grafana.nix: recreate the pod when HostAdd drifts.
  podUnit = { name, members, script }: {
    description = "Pod ${name}";
    wantedBy = [ "multi-user.target" ];
    before = map (m: "podman-${m}.service") members;
    after = [ "podman-def0.service" ];
    requires = [ "podman-def0.service" ];
    requiredBy = map (m: "podman-${m}.service") members;
    unitConfig.RequiresMountsFor = "/run/containers";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pod-${name}-create" ''
        set -euo pipefail
        hostGw="$(${pkgs.iproute2}/bin/ip -4 -o addr show podman0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        if [ -z "''${hostGw}" ]; then hostGw="10.88.0.1"; fi
        ${script}
      '';
    };
    path = [ pkgs.podman pkgs.iproute2 pkgs.gawk pkgs.gnugrep ];
  };

  hostHttpd = port: {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.busybox}/bin/httpd -f -p 0.0.0.0:${toString port} -h ${pkgs.writeTextDir "index.html" "host-${toString port}"}";
  };
in
{
  imports = [ ../../nixos/containers/pod-infra.nix ];

  virtualisation.memorySize = 3072;
  virtualisation.cores = 4;
  virtualisation.diskSize = 4096;
  boot.kernelPackages = pkgs.linuxPackages_latest; # ace: 7.3 -> 7.3.1
  system.switch.enable = true;
  boot.loader.grub.enable = false; # VM boots its kernel directly
  # The live-switch test changes the backdoor's store paths; keep the driver's shell.
  systemd.services.backdoor.restartIfChanged = false;

  virtualisation.containers.enable = true;
  virtualisation.podman = { enable = true; dockerCompat = true; };
  virtualisation.oci-containers.backend = "podman";
  environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.nftables pkgs.iptables pkgs.podman-tui ];

  # ace: iptables backend, podman0 not trusted, only these host ports opened on it.
  networking.firewall.enable = true;
  networking.firewall.interfaces.podman0 = {
    allowedTCPPorts = [ 53 80 443 2020 3100 9100 9115 ];
    allowedUDPPorts = [ 53 443 ];
  };
  # ace github-runner/network.nix pattern: raw + FORWARD chains for an isolated bridge.
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -t raw -N t-ghr-raw 2>/dev/null || iptables -t raw -F t-ghr-raw
    iptables -t raw -A t-ghr-raw -d 10.88.0.0/16 -j DROP
    iptables -t raw -D PREROUTING -i ghr0 -j t-ghr-raw 2>/dev/null || true
    iptables -t raw -I PREROUTING 1 -i ghr0 -j t-ghr-raw
    iptables -N t-ghr-fwd 2>/dev/null || iptables -F t-ghr-fwd
    iptables -A t-ghr-fwd -d 192.168.0.0/16 -j DROP
    iptables -D FORWARD -i ghr0 -j t-ghr-fwd 2>/dev/null || true
    iptables -I FORWARD 1 -i ghr0 -j t-ghr-fwd
    iptables -I nixos-fw 1 -i ghr0 -j nixos-fw-refuse
    # pushgateway.nix pattern
    iptables -t raw -D PREROUTING -p tcp --dport 9091 ! -i podman0 ! -s 192.168.1.250 -j DROP 2>/dev/null || true
    iptables -t raw -A PREROUTING -p tcp --dport 9091 ! -i podman0 ! -s 192.168.1.250 -j DROP
  '';

  systemd.services.host-9100 = hostHttpd 9100; # allowed on podman0 (node_exporter)
  systemd.services.host-9999 = hostHttpd 9999; # not allowed on podman0

  # --- zitadel.nix pattern: pod + postgres + app, dependsOn, healthchecks ---
  systemd.services.pod-zt = podUnit {
    name = "zt";
    members = [ "zt-db" "zt-app" ];
    script = ''
      if podman pod exists zt-pod; then
        additions="$(podman pod inspect zt-pod --format '{{range .InfraConfig.HostAdd}}{{.}} {{end}}' 2>/dev/null || true)"
        if [ -z "''${additions}" ] || ! printf '%s' "''${additions}" | grep -q "zt.example:''${hostGw}"; then
          echo "pod-zt: HostAdd drift ('$additions'), recreating" >&2
          podman pod stop -t 10 zt-pod || true
          podman pod rm -f zt-pod || true
        fi
      fi
      if ! podman pod exists zt-pod; then
        podman pod create --name zt-pod --add-host=zt.example:''${hostGw} \
          -p 127.0.0.1:9080:80 -p 127.0.0.1:9081:5432 --memory 1G --cpus 0
      fi
    '';
  };
  virtualisation.oci-containers.containers.zt-db = postgres // {
    environment.POSTGRES_PASSWORD = "test";
    extraOptions = [ "--pod=zt-pod" "--health-cmd=pg_isready -U postgres" "--health-interval=3s" ];
  };
  virtualisation.oci-containers.containers.zt-app = tbox // {
    dependsOn = [ "zt-db" ];
    extraOptions = [ "--pod=zt-pod" "--health-cmd=wget -q -O /dev/null http://127.0.0.1/" "--health-interval=3s" ];
  };

  # --- grafana.nix pattern: host-gateway, --dns, publish on 127.0.0.1 and 10.88.0.1 ---
  systemd.services.pod-gf = podUnit {
    name = "gf";
    members = [ "gf" ];
    script = ''
      if podman pod exists gf-pod; then
        if ! podman pod inspect gf-pod --format '{{range .InfraConfig.HostAdd}}{{.}} {{end}}' | grep -q "zt.example:''${hostGw}"; then
          echo "pod-gf: HostAdd drift, recreating" >&2
          podman pod stop -t 10 gf-pod || true
          podman pod rm -f gf-pod || true
        fi
      fi
      if ! podman pod exists gf-pod; then
        podman pod create --name gf-pod --add-host=zt.example:''${hostGw} \
          --add-host=host.containers.internal:host-gateway --dns=10.88.0.1 \
          -p 127.0.0.1:8082:80 -p 10.88.0.1:8082:80 --memory 1G --cpus 0
      fi
    '';
  };
  virtualisation.oci-containers.containers.gf = tbox // { extraOptions = [ "--pod=gf-pod" ]; };

  # --- coolify.nix pattern: custom network (podman1), DNS by name, ports ---
  systemd.services.tnet-network = {
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-web1.service" "podman-web2.service" "podman-tclient.service" ];
    requiredBy = [ "podman-web1.service" "podman-web2.service" "podman-tclient.service" ];
    unitConfig.RequiresMountsFor = [ "/run/containers" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = "${podman} network exists tnet || ${podman} network create tnet";
  };
  virtualisation.oci-containers.containers.web1 = tbox // {
    ports = [ "127.0.0.1:8181:80" ];
    extraOptions = [ "--network=tnet" ];
  };
  virtualisation.oci-containers.containers.web2 = tbox // {
    ports = [ "0.0.0.0:8182:80" ];
    extraOptions = [ "--network=tnet" ];
  };
  virtualisation.oci-containers.containers.tclient = tbox // {
    dependsOn = [ "web1" "web2" ];
    cmd = [ "sleep" "infinity" ];
    extraOptions = [ "--network=tnet" ];
  };

  # --- default network (podman0) container published on the gateway (prometheus pattern) ---
  virtualisation.oci-containers.containers.def1 = tbox // { ports = [ "10.88.0.1:8190:80" ]; };
  # 10.88.0.1 exists only while some podman0 container runs (on ace: prometheus etc.).
  virtualisation.oci-containers.containers.def0 = tbox;
  systemd.services.podman-def1 = { after = [ "podman-def0.service" ]; requires = [ "podman-def0.service" ]; };

  # --- github-runner/network.nix pattern: isolate=true, custom ifname, no DNS ---
  systemd.services.ghr-network = {
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-ghrc.service" ];
    requiredBy = [ "podman-ghrc.service" ];
    after = [ "firewall.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.podman ];
    script = ''
      podman network exists ghr && exit 0
      podman network create --driver bridge --interface-name ghr0 --subnet 10.250.250.0/24 \
        --disable-dns --opt isolate=true ghr
    '';
  };
  virtualisation.oci-containers.containers.ghrc = tbox // {
    cmd = [ "sleep" "infinity" ];
    extraOptions = [ "--network=ghr" "--dns-search=." ];
  };

  environment.etc."podman-check.sh".source = ./check.sh;
}
