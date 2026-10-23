# Mars: Dell PowerEdge R410 (docs/mars.md). Headless Coolify deploy and build
# server; Coolify itself runs on ace. Installed with nixos-anywhere from ace.
{ config, inputs, lib, pkgs, ... }:

let
  marsIp = "192.168.5.15";
  bootstrapPubkey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAZG4s8GtqKZoahIUsFwbXsMnuUrrlSDmN2nzt39pDiS bootstrap@homelab";
  # Only from ace itself, and never for forwarding.
  aceDeployPubkey =
    ''from="192.168.5.5",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEMydexGEchoOPoh8jDiecyTkmgj/Tfxap7U+lQQfPW root@ace (nixos-configs automation)'';
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware.nix
    ../../nixos
    ../../nixos/security
    ../../nixos/monitoring/promtail.nix
    ../../nixos/coolify-node.nix
    ../../users/prestonh
  ];

  # Legacy BIOS only (no UEFI on the R410): GRUB, not the systemd-boot that
  # nixos/default.nix enables for the UEFI hosts.
  boot.loader.grub.enable = true;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  networking = {
    hostName = "mars";
    useDHCP = false;
    interfaces.eno1 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = marsIp;
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.5.1";
    nameservers = [ "192.168.5.5" "1.1.1.1" ];
    hosts = {
      "192.168.5.5" = [
        "panel.prestonhager.com"
        "ace.internal.prestonhager.com"
      ];
      ${marsIp} = [ "mars.internal.prestonhager.com" ];
    };
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # Only the host SSH key decrypts sops here. nixos/default.nix also names
  # /var/lib/sops/age/keys.txt (ace has one); a missing keyFile makes
  # sops-install-secrets abort, so users came up without passwords.
  sops.age.keyFile = lib.mkForce null;

  homelab.coolifyNode = {
    address = marsIp;
    lanInterface = "eno1";
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # root@ace deploys with its own key (nixos/ace-git-identity.nix); the bootstrap
  # key is the workstation key. Coolify's key comes from coolify-node.nix.
  users.users.root.openssh.authorizedKeys.keys = [ bootstrapPubkey aceDeployPubkey ];
  users.users.prestonh.openssh.authorizedKeys.keys = [ bootstrapPubkey ];
  # Only declared keys count (nixos/security/ssh.nix); bootstrapPubkey is the
  # admin workstation's key, so this cannot lock the workstation out.
  homelab.security.ssh.declarativeKeysOnly = true;

  # Coolify deploys and builds with this Docker (it never installs its own).
  virtualisation.docker = {
    enable = true;
    liveRestore = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--filter" "until=168h" ];
    };
  };

  homelab.security = {
    enable = true;
    hostName = config.networking.hostName;
    role = "node";
    phase2.enable = true;
    promtail.enable = true;
  };
}
