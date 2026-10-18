#!/usr/bin/env bash
# Phase 3 stub — drop inbound from IP on ace (nftables, non-persistent).
# Usage: block-ip-nftables.sh 203.0.113.50
set -euo pipefail
IP="${1:?source IP required}"
IFACE="${HOMELAB_BLOCK_IFACE:-bond0}"

if [[ "$IP" =~ ^192\.168\.5\. ]]; then
  echo "Refusing to block LAN IP $IP — investigate host instead." >&2
  exit 1
fi

nft add table inet homelab_block 2>/dev/null || true
nft 'add chain inet homelab_block input { type filter hook input priority 0; }' 2>/dev/null || true
nft add rule inet homelab_block input iifname "$IFACE" ip saddr "$IP" counter drop \
  && logger -t homelab-response "nftables drop $IP on $IFACE"
echo "Dropped inbound from $IP on $IFACE (table inet homelab_block)."
