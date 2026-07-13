{ config, inputs, pkgs, lib ? pkgs.lib, ... }:

{
  networking.hostName = "ace";

  imports = [
    ../../nixos/local-service-hosts.nix
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
    # GitHub Actions self-hosted runners — docs/github-runner.md
    ../../nixos/services/github-runner.nix
    # hardware configuration for the MSI Summit E16 Flip
    ../../hardware/dell-poweredge-730xd/hardware-configuration.nix
    # yubico keys
    ../../nixos/yubikey.nix
    # include any users
    ../../users/prestonh
    ../../users/dylanh
    # K80 GPU stack (Tesla K80 / legacy 470) — docs/ace-k80-gpu.md
    inputs.ace-k80-stack.nixosModules.k80-gpu
  ];

  # 32 GiB swap file on root (sdb2, ~2.9T free) — safety net for rebuild memory
  # pressure. Chosen over zram: disk-backed swap does not compete with the
  # compressed-RAM budget on a 31 GiB host. Created on activation when size is set.
  # Pending constrained rebuild — do not apply unconstrained. See docs/ace-rebuild-freeze-rca.md.
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 32 * 1024; # MiB
  }];

  # Memory-bound host: keep concurrent derivations low, give each build more cores.
  nix.settings = {
    max-jobs = 4;
    cores = 12;
  };

  # Add prestonh to jellyfin group to allow for rsync into /jf/media folder
  users.users.prestonh.extraGroups = [ "jellyfin" ];

  # Add lynis an auditing tool to system packages
  environment.systemPackages = with pkgs; [
    lynis
  ];

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
      interfaces = [ "eno1" "eno2" ];
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
  };

  # Cloudflare DNS-01 for Caddy TLS (token in nix-secrets secrets/cloudflare.yaml).
  homelab.caddy.cloudflareAcme = {
    enable = true;
    accountId = "12f5428fd594b9e9c2eaadfdd0fdc857";
  };

  # --- K80 GPU stack (Tesla K80 / legacy 470) ---
  # See docs/ace-k80-gpu.md and https://github.com/PrestonHager/ace-k80-stack
  # Insecure packages required on ace (literal names — avoid pkgs.*.version here).
  # - openclaw: LLM gateway for ai.prestonhager.com (TEMPORARILY DISABLED — re-add when re-enabling)
  # - nodejs 20 / slim: GitHub Actions runner externals/node20 + parityPackages
  nixpkgs.config.permittedInsecurePackages = [
    # "openclaw-2026.6.5"  # TEMPORARILY DISABLED with OpenClaw / ai.prestonhager.com
    "nodejs-20.20.2"
    "nodejs-slim-20.20.2"
  ];
  services.aceK80 = {
    enable = true;
    enableOllama = true;
    # TEMPORARILY DISABLED — reopen ai.prestonhager.com later (docs/ace-openclaw-sso.md)
    enableOpenClaw = false;
    # openclaw.package = pkgs.openclaw;
  };

  # GitHub Actions runners ? Ubuntu Noble OCI via baked local image
  # (localhost/homelab-github-runner:ubuntu-noble from myoung34 + apt/cross).
  # Profiling 2026-07-12 on ace: 48 CPUs, 31 GiB RAM + 32 GiB swap; ~7 GiB steady
  # for web stacks. N=4 � 4096m � 4 CPUs ? 16 GiB / 16 CPUs peak CI; rest for
  # Nextcloud/Pterodactyl/Matrix/Grafana/Caddy and nix max-jobs=4.
  # PrestonHager is a personal account (not an org): no user/org-wide runners
  # (GitHub API 404). All four register to soundbytes-app (primary CI consumer).
  # Token: nix-secrets secrets/github-runner.yaml ? token
  # Workflows: runs-on: ace-ubuntu-x64-4  (GitHub also adds self-hosted/Linux/X64)
  # Ops: docs/github-runner.md (ghost recovery, image bake, workdir wipe)
  homelab.github-runners = {
    enable = true;
    backend = "container";
    containerMemory = "4096m";
    containerCpus = "4";
    runners = {
      ace = {
        url = "https://github.com/PrestonHager/soundbytes-app";
        instances = 4;
        extraLabels = [ "ace-ubuntu-x64-4" ];
      };
    };
  };
}
