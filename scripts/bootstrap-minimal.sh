#!/usr/bin/env bash
# bootstrap-minimal.sh — install a tiny NixOS stage0 for nixos-anywhere
#
# Run from a NixOS installer image (USB/ISO/netboot). After reboot, the machine
# should be reachable on the LAN over any ethernet NIC (DHCP) with SSH as root.
# Then install the real host with nixos-anywhere from another machine.
#
# Download & run from the installer:
#   curl -fsSL https://raw.githubusercontent.com/PrestonHager/nixos-configs/main/scripts/bootstrap-minimal.sh | sudo bash
#
# Or from your LAN (example):
#   curl -fsSL http://192.168.5.5/bootstrap-minimal.sh | sudo bash -s -- --disk /dev/sda -k 'ssh-ed25519 AAAA...'
#
# Non-interactive example:
#   sudo bash bootstrap-minimal.sh -y -d /dev/nvme0n1 -k 'ssh-ed25519 AAAA...' -H bootstrap-optiplex
#
set -euo pipefail

BOOTSTRAP_HOST="${HOSTNAME_OVERRIDE:-nixos-bootstrap}"
DISK="${DISK:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ASSUME_YES=0
SWAP_SIZE=""
NIXOS_CHANNEL="${NIXOS_CHANNEL:-nixos-unstable}"

ESP_PART=""
ROOT_PART=""
SWAP_PART=""
GENERATED_PASSWORD=0
SSH_KEYS=()

usage() {
  cat <<EOF
Usage: sudo bash bootstrap-minimal.sh [options]

Install a minimal NixOS to disk: DHCP on all ethernet NICs + SSH root access.
Intended as a stage0 target for nixos-anywhere (which will wipe/repartition).

Options:
  -d, --disk PATH           Target disk (e.g. /dev/nvme0n1, /dev/sda)
  -k, --ssh-key KEY         SSH public key for root (may be repeated)
  -f, --ssh-key-file PATH   Read SSH public key(s) from a file
  -H, --hostname NAME       Hostname (default: nixos-bootstrap)
  -p, --root-password PASS  Root password (default: random, printed at end)
      --swap SIZE           Optional swap size for sgdisk, e.g. 2G (default: none)
  -y, --yes                 Non-interactive; requires --disk
  -h, --help                Show this help

Env: DISK, SSH_AUTHORIZED_KEY, SSH_KEY_FILE, ROOT_PASSWORD, HOSTNAME_OVERRIDE,
     NIXOS_CHANNEL (default: nixos-unstable)
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (are you in a NixOS installer?)"
}

add_ssh_key() {
  local key="$1"
  key="$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$key" ]] || return 0
  [[ "$key" == \#* ]] && return 0
  case "$key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@*\ *|sk-ecdsa-sha2-*\ *)
      SSH_KEYS+=("$key")
      ;;
    *)
      die "does not look like an SSH public key: ${key:0:40}..."
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--disk)
        DISK="${2:?--disk requires a path}"; shift 2 ;;
      -k|--ssh-key)
        add_ssh_key "${2:?--ssh-key requires a value}"; shift 2 ;;
      -f|--ssh-key-file)
        SSH_KEY_FILE="${2:?--ssh-key-file requires a path}"; shift 2 ;;
      -H|--hostname)
        BOOTSTRAP_HOST="${2:?--hostname requires a name}"; shift 2 ;;
      -p|--root-password)
        ROOT_PASSWORD="${2:?--root-password requires a value}"; shift 2 ;;
      --swap)
        SWAP_SIZE="${2:?--swap requires a size}"; shift 2 ;;
      -y|--yes)
        ASSUME_YES=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "unknown option: $1 (try --help)" ;;
    esac
  done
}

load_key_sources() {
  if [[ -n "$SSH_AUTHORIZED_KEY" ]]; then
    add_ssh_key "$SSH_AUTHORIZED_KEY"
  fi
  if [[ -n "$SSH_KEY_FILE" ]]; then
    [[ -r "$SSH_KEY_FILE" ]] || die "cannot read SSH key file: $SSH_KEY_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
      add_ssh_key "$line"
    done < "$SSH_KEY_FILE"
  fi
}

ensure_tools() {
  # Prefer tools already on the ISO; pull a few via nix-env if missing.
  if ! command -v sgdisk >/dev/null 2>&1; then
    log "installing gptfdisk into installer profile"
    nix-env -iA nixos.gptfdisk >/dev/null
  fi
  if ! command -v wipefs >/dev/null 2>&1; then
    log "installing util-linux (wipefs) into installer profile"
    nix-env -iA nixos.util-linux >/dev/null
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    log "installing openssl into installer profile"
    nix-env -iA nixos.openssl >/dev/null
  fi
}

check_installer_env() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
  ensure_tools
  need_cmd lsblk
  need_cmd sgdisk
  need_cmd mkfs.fat
  need_cmd mkfs.ext4
  need_cmd mount
  need_cmd nixos-generate-config
  need_cmd nixos-install
  need_cmd nix-channel
  need_cmd ip
  need_cmd openssl
  need_cmd wipefs
  if [[ ! -e /etc/NIXOS ]]; then
    warn "/etc/NIXOS not found — this does not look like a NixOS installer; continuing anyway"
  fi
}

list_candidate_disks() {
  lsblk -dn -o NAME,TYPE | awk '$2 == "disk" && $1 !~ /^(loop|ram|zram|fd)/ { print "/dev/" $1 }'
}

prompt_disk() {
  local disks=() choice i
  mapfile -t disks < <(list_candidate_disks)
  [[ ${#disks[@]} -gt 0 ]] || die "no disks found"

  echo
  echo "Available disks:"
  lsblk -d -o NAME,SIZE,TYPE,TRAN,RM,MODEL
  echo
  for i in "${!disks[@]}"; do
    printf '  [%d] %s\n' "$((i + 1))" "${disks[$i]}"
  done
  echo
  read -r -p "Select disk number to WIPE and install to: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || die "invalid selection"
  i=$((choice - 1))
  [[ $i -ge 0 && $i -lt ${#disks[@]} ]] || die "selection out of range"
  DISK="${disks[$i]}"
}

confirm_wipe() {
  local answer
  echo
  warn "ALL DATA ON $DISK WILL BE DESTROYED."
  lsblk "$DISK"
  echo
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "assuming yes (--yes)"
    return 0
  fi
  read -r -p "Type the disk path ($DISK) to confirm: " answer
  [[ "$answer" == "$DISK" ]] || die "confirmation failed"
}

detect_boot_mode() {
  if [[ -d /sys/firmware/efi ]]; then
    echo efi
  else
    echo bios
  fi
}

part_name() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

wait_for_part() {
  local part="$1" tries=50
  while [[ ! -b "$part" && $tries -gt 0 ]]; do
    sleep 0.2
    tries=$((tries - 1))
  done
  [[ -b "$part" ]] || die "partition did not appear: $part"
}

partition_disk() {
  local boot_mode="$1"

  log "wiping signatures and partition table on $DISK"
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  wipefs -a "$DISK" 2>/dev/null || true
  sgdisk --zap-all "$DISK" >/dev/null

  if [[ "$boot_mode" == efi ]]; then
    log "creating GPT: ESP + root (+ optional swap)"
    sgdisk -n1:0:+512M -t1:EF00 -c1:ESP "$DISK" >/dev/null
    if [[ -n "$SWAP_SIZE" ]]; then
      sgdisk -n2:0:+"$SWAP_SIZE" -t2:8200 -c2:swap "$DISK" >/dev/null
      sgdisk -n3:0:0 -t3:8300 -c3:root "$DISK" >/dev/null
    else
      sgdisk -n2:0:0 -t2:8300 -c2:root "$DISK" >/dev/null
    fi
  else
    log "creating GPT: BIOS boot + root (+ optional swap)"
    sgdisk -n1:0:+1M -t1:EF02 -c1:biosboot "$DISK" >/dev/null
    if [[ -n "$SWAP_SIZE" ]]; then
      sgdisk -n2:0:+"$SWAP_SIZE" -t2:8200 -c2:swap "$DISK" >/dev/null
      sgdisk -n3:0:0 -t3:8300 -c3:root "$DISK" >/dev/null
    else
      sgdisk -n2:0:0 -t2:8300 -c2:root "$DISK" >/dev/null
    fi
  fi

  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DISK" 2>/dev/null || true
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle 2>/dev/null || true
  else
    sleep 1
  fi

  if [[ "$boot_mode" == efi ]]; then
    ESP_PART="$(part_name "$DISK" 1)"
    if [[ -n "$SWAP_SIZE" ]]; then
      SWAP_PART="$(part_name "$DISK" 2)"
      ROOT_PART="$(part_name "$DISK" 3)"
    else
      SWAP_PART=""
      ROOT_PART="$(part_name "$DISK" 2)"
    fi
  else
    ESP_PART=""
    if [[ -n "$SWAP_SIZE" ]]; then
      SWAP_PART="$(part_name "$DISK" 2)"
      ROOT_PART="$(part_name "$DISK" 3)"
    else
      SWAP_PART=""
      ROOT_PART="$(part_name "$DISK" 2)"
    fi
  fi

  wait_for_part "$ROOT_PART"
  [[ -z "$ESP_PART" ]] || wait_for_part "$ESP_PART"
  [[ -z "$SWAP_PART" ]] || wait_for_part "$SWAP_PART"
}

format_and_mount() {
  local boot_mode="$1"

  log "formatting filesystems"
  if [[ "$boot_mode" == efi ]]; then
    mkfs.fat -F32 -n ESP "$ESP_PART"
  fi
  mkfs.ext4 -F -L nixos "$ROOT_PART"
  if [[ -n "$SWAP_PART" ]]; then
    mkswap -L swap "$SWAP_PART"
  fi

  log "mounting under /mnt"
  umount -R /mnt 2>/dev/null || true
  mount "$ROOT_PART" /mnt
  if [[ "$boot_mode" == efi ]]; then
    mkdir -p /mnt/boot
    mount "$ESP_PART" /mnt/boot
  fi
  if [[ -n "$SWAP_PART" ]]; then
    swapon "$SWAP_PART"
  fi
}

generate_root_password() {
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)"
    GENERATED_PASSWORD=1
  else
    GENERATED_PASSWORD=0
  fi
  ROOT_HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"
}

# Nix ''...'' strings: '' is written as '''
nix_escape_indented() {
  printf '%s' "$1" | sed "s/''/'''/g"
}

write_configuration() {
  local boot_mode="$1"
  local keys_nix="" k escaped bootloader_nix

  mkdir -p /mnt/etc/nixos

  if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
    keys_nix=$'\n'
    for k in "${SSH_KEYS[@]}"; do
      escaped="$(nix_escape_indented "$k")"
      keys_nix+="      ''${escaped}''"$'\n'
    done
  fi

  if [[ "$boot_mode" == efi ]]; then
    bootloader_nix=$(cat <<'NIX'
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.grub.enable = false;
NIX
)
  else
    bootloader_nix=$(cat <<NIX
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "${DISK}";
  boot.loader.systemd-boot.enable = false;
NIX
)
  fi

  log "writing minimal /mnt/etc/nixos/configuration.nix"
  cat > /mnt/etc/nixos/configuration.nix <<NIX
# Generated by bootstrap-minimal.sh — stage0 for nixos-anywhere.
# Intentionally tiny: ethernet DHCP + SSH root access.
{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "${BOOTSTRAP_HOST}";

${bootloader_nix}

  # DHCP on every ethernet adapter (match Type=ether → en*, eth*, etc.). No Wi-Fi.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.usePredictableInterfaceNames = true;
  systemd.network.enable = true;
  systemd.network.networks."10-ethernet" = {
    matchConfig.Type = "ether";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };
  # Don't hang boot if a NIC has no link yet.
  systemd.network.wait-online.enable = false;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.root = {
    hashedPassword = "${ROOT_HASH}";
    openssh.authorizedKeys.keys = [${keys_nix}    ];
  };

  environment.systemPackages = with pkgs; [ vim curl git iproute2 ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  system.stateVersion = "24.11";
}
NIX

  log "generating hardware-configuration.nix"
  nixos-generate-config --root /mnt
}

ensure_channel() {
  if ! nix-channel --list | awk '{print $1}' | grep -qx nixos; then
    log "adding nixos channel (${NIXOS_CHANNEL})"
    nix-channel --add "https://nixos.org/channels/${NIXOS_CHANNEL}" nixos
    nix-channel --update
  else
    log "nixos channel already present"
  fi
}

run_install() {
  log "running nixos-install"
  # Root password is already in configuration.nix; skip interactive prompt.
  nixos-install --root /mnt --no-root-passwd --no-channel-copy
}

show_network_hints() {
  echo
  log "addresses visible in the installer (stage0 will use DHCP on ethernet):"
  ip -br addr show || true
  echo
  ip -4 -o addr show scope global 2>/dev/null | awk '{ print "  " $2 "  " $4 }' || true
}

print_summary() {
  local key_count=${#SSH_KEYS[@]}
  cat <<EOF

========================================================================
 Minimal NixOS stage0 install complete
========================================================================
  Disk:       $DISK
  Hostname:   $BOOTSTRAP_HOST
  Boot:       $(detect_boot_mode)
  SSH keys:   ${key_count} authorized for root
  Root pass:  ${ROOT_PASSWORD}

Next steps:
  1. Reboot into the new system:
       reboot

  2. From your admin machine (same LAN), install the real host:
       nix run github:nix-community/nixos-anywhere -- \\
         --flake .#<host> \\
         --target-host root@<ip>

  Find <ip> via your DHCP leases or: ping / nmap / router UI.
  Prefer key auth by passing -k / --ssh-key during bootstrap.

  Note: nixos-anywhere will wipe and repartition the disk again (disko).
========================================================================
EOF
  if [[ "$key_count" -eq 0 ]]; then
    warn "No SSH public keys installed — use the root password above with nixos-anywhere."
  fi
}

main() {
  parse_args "$@"
  load_key_sources
  check_installer_env

  if [[ -z "$DISK" ]]; then
    [[ "$ASSUME_YES" -eq 0 ]] || die "--yes requires --disk"
    prompt_disk
  fi
  [[ -b "$DISK" ]] || die "not a block device: $DISK"

  confirm_wipe
  generate_root_password

  local boot_mode
  boot_mode="$(detect_boot_mode)"
  log "boot mode: $boot_mode"

  partition_disk "$boot_mode"
  format_and_mount "$boot_mode"
  ensure_channel
  write_configuration "$boot_mode"
  run_install
  show_network_hints
  print_summary
}

main "$@"
