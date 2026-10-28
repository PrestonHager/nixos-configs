{ config, inputs, pkgs, lib ? pkgs.lib, ... }:

let
  sops-path = builtins.toString inputs.nix-secrets;
in {
  networking.hostName = "ace";

  imports = [
    ../../nixos/containers/blueprint-plugins.nix
    # unblocks nixpkgs python3.12-inline-snapshot test failure (ceph/samba/HM chain)
    ../../modules/overlays-inline-snapshot.nix
    ../../nixos/local-service-hosts.nix
    # root's own GitHub + signing key (no agent forwarding needed)
    ../../nixos/ace-git-identity.nix
    # Nightly DB dumps + restic snapshots to /stor
    ../../nixos/backup.nix
    ../../nixos
    ../../nixos/headless
    ../../nixos/security
    ../../nixos/nextcloud-migrate.nix
    # Samba share for Windows (Steam library on /var/lib/ace-drive, root volume)
    ../../nixos/samba
    # include nfs for caddy lets encrypt certs
    ../../nixos/nfs
    # matrix home server (Synapse)
    ../../nixos/matrix.nix
    # GitHub Actions self-hosted runners � docs/github-runner.md
    ../../nixos/services/github-runner.nix
    # hardware configuration for the MSI Summit E16 Flip
    ../../hardware/dell-poweredge-730xd/hardware-configuration.nix
    # yubico keys
    ../../nixos/yubikey.nix
    # include any users
    ../../users/prestonh
    ../../users/dylanh
  ];

  sops.secrets."tailscale-auth-key" = {
    sopsFile = "${sops-path}/secrets/ace.yaml";
  };

  # 32 GiB swap file on root (sdb2, ~2.9T free) � safety net for rebuild memory
  # pressure. Chosen over zram: disk-backed swap does not compete with the
  # compressed-RAM budget on a 31 GiB host. Created on activation when size is set.
  # Pending constrained rebuild � do not apply unconstrained. See docs/ace-rebuild-freeze-rca.md.
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 32 * 1024; # MiB
  }];

  # Redis (coolify-redis and the other Redis containers) warns "Memory overcommit
  # must be enabled" and can fail BGSAVE/fork under memory pressure without it.
  # The vm.overcommit_* entries in nixos/default.nix boot.kernelParams lack the
  # sysctl. prefix and are ignored by the kernel, so set it here.
  boot.kernel.sysctl."vm.overcommit_memory" = 1;

  # Memory-bound host: keep concurrent derivations low, give each build more cores.
  nix.settings = {
    max-jobs = 4;
    cores = 12;
  };

  # Add prestonh to jellyfin group to allow for rsync into /jf/media folder
  users.users.prestonh.extraGroups = [ "jellyfin" ];

  # Add lynis an auditing tool and the Claude Code CLI to system packages
  environment.systemPackages = with pkgs; [
    lynis
    claude-code
  ];

  # Run generic (non-Nix) Linux binaries, e.g. the Claude CLI that the Claude
  # desktop app downloads to ~/.claude/remote for SSH sessions.
  programs.nix-ld.enable = true;

  # Configure networking for the host
  networking = {
    defaultGateway = "192.168.5.1";
    # Technitium on ace (192.168.5.5:53); avoid looping through external resolvers first.
    nameservers = [ "192.168.5.5" "1.1.1.1" ];
    interfaces.bond0 = {
      useDHCP = false;
      ipv4.addresses = [ {
        address = "192.168.5.5";
        prefixLength = 24;
      } ];
    };
    bonds.bond0 = {
      interfaces = [ "eno1" "eno3" ];
      driverOptions = {
        mode = "802.3ad";
        lacp_rate = "fast";
        miimon = "100";
      };
    };

    # Setup local IP's for other servers
    hosts = {
      "192.168.5.6" = [
        "crux.lc1.nm.us.prestonhager.com"
      ];
    };
  };

  # Never tear down the uplink during a live switch. On 2026-10-24 a nixpkgs
  # update changed these units; the switch restarted bond0-netdev (which deletes
  # and recreates the bond) and the address units, but not network-setup, which
  # owns the default route. ace was left with no default route, unreachable from
  # other subnets and the internet, until a hard reset. Changes to these units
  # now apply at the next boot.
  systemd.services = lib.genAttrs [
    "bond0-netdev"
    "network-addresses-bond0"
    "network-addresses-eno1"
    "network-addresses-eno3"
    "network-setup"
  ] (_: { restartIfChanged = false; }) // {
    # NetworkManager-wait-online times out on this host every boot/switch and
    # makes nixos-rebuild switch return non-zero. Disable the wait entirely.
    NetworkManager-wait-online.enable = lib.mkForce false;
  };

  homelab.security = {
    enable = true;
    hostName = "ace";
    role = "central";
    phase2.enable = true;
    cisco.enable = true;
    # Set true after adding secrets/cisco.yaml to nix-secrets (TC-1.3).
    cisco.backup.enable = false;
    loki.enable = true;
    promtail.enable = true;
    suricata.enable = true;
    # AbuseIPDB blacklist -> BGP blackhole routes on Astracap
    # (docs/network-abuseipdb-blackhole.md). Flip apiKeyConfigured after adding the
    # key to nix-secrets, and routerConfigured after pasting the router config.
    abuseipdbBlackhole = {
      enable = true;
      apiKeyConfigured = true;
      routerConfigured = true;
    };
  };

  # Both panels run Hydrodactyl (docs/hydrodactyl-migration-plan.md).
  homelab.panel.prod.flavor = "hydrodactyl";
  homelab.panel.test.flavor = "hydrodactyl";
  # Throwaway Wings node for test.panel (no access to the real nodes).
  homelab.panel.test.wingsNode.enable = true;

  # Cloudflare DNS-01 for Caddy TLS (token in nix-secrets secrets/cloudflare.yaml).
  homelab.caddy.cloudflareAcme = {
    enable = true;
    accountId = "12f5428fd594b9e9c2eaadfdd0fdc857";
  };

  # GitHub Actions runners -- Amazon Linux 2023 OCI (glibc 2.34) via baked local
  # image (localhost/homelab-github-runner:al2023). Matches AWS Lambda
  # provided.al2023 so soundbytes-api bootstrap binaries link correctly.
  # Profiling 2026-07-12 on ace: 48 CPUs, 31 GiB RAM + 32 GiB swap; ~7 GiB steady
  # for web stacks. Originally N=4 x 4096m x 4 CPUs => 16 GiB / 16 CPUs peak CI.
  # With EverPuzzle: N=8 same caps => 32 GiB / 32 CPUs peak � tight vs web
  # services; rely on swap and hard memory caps. Prefer same caps unless OOM.
  # PrestonHager is a personal account (not an org): no user/org-wide runners
  # (GitHub API 404). Repo-scoped sets: soundbytes-app (ace-1�4) + EverPuzzle
  # (ace-ep-1�4). systemd/podman unit names must be unique on the host, so
  # EverPuzzle uses the ace-ep-* attr (GitHub UI names match units).
  # Token: nix-secrets secrets/github-runner.yaml -> token (shared PAT).
  # Preferred workflow label: ace-al2023-x64-4 (GitHub also adds self-hosted/Linux/X64).
  # Also advertise ace-ubuntu-x64-4 until workflows finish migrating --
  # otherwise online AL2023 runners stay idle while jobs queue on the old label.
  # Ops: docs/github-runner.md (ghost recovery, image bake, workdir wipe)
  homelab.github-runners = {
    enable = true;
    backend = "container";
    containerImage = "localhost/homelab-github-runner:al2023";
    containerBaseImage = "docker.io/amazonlinux:2023";
    containerfile = ../../nixos/services/github-runner/Containerfile.al2023;
    containerMemory = "4096m";
    containerCpus = "4";
    runners = {
      ace = {
        url = "https://github.com/PrestonHager/soundbytes-app";
        instances = 4;
        extraLabels = [ "ace-al2023-x64-4" "ace-ubuntu-x64-4" ];
      };
      # GitHub + systemd: ace-ep-1 � ace-ep-4 (unique host units; labels match soundbytes)
      ace-ep = {
        url = "https://github.com/PrestonHager/EverPuzzle";
        instances = 4;
        extraLabels = [ "ace-al2023-x64-4" "ace-ubuntu-x64-4" ];
      };
    };
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale-auth-key".path;
    openFirewall = true;
    useRoutingFeatures = "server";
    extraUpFlags = [ "--advertise-exit-node" ];
  };
}
