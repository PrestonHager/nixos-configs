#!/usr/bin/env bash
# Bootstrap encrypted sops secrets for Zitadel + Grafana OIDC on ace.
# Run from /etc/nixos after updating nixos-secrets checkout.
set -euo pipefail

SECRETS="${1:-/home/prestonh/nixos-secrets}"
CONTAINERS="${SECRETS}/secrets/containers"

if ! command -v sops >/dev/null 2>&1; then
  echo "sops not found; install sops or run from a nix shell with sops." >&2
  exit 1
fi

for pair in \
  "zitadel-config.yaml.template:zitadel-config.yaml" \
  "grafana-oauth.yaml.template:grafana-oauth.yaml"; do
  src="${CONTAINERS}/${pair%%:*}"
  dst="${CONTAINERS}/${pair##*:}"
  if [[ -f "$dst" ]]; then
    echo "exists: $dst (edit with: sops $dst)"
    continue
  fi
  cp "$src" "$dst"
  echo "Created $dst — edit secrets, then: sops -e -i $dst"
done

echo
echo "After editing and encrypting:"
echo "  cd /etc/nixos && nix flake update nix-secrets"
echo "  nixos-rebuild switch --flake /etc/nixos#ace"
