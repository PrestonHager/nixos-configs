#!/usr/bin/env bash
# Upsert grey-cloud CNAME records in Cloudflare for ace-hosted prestonhager.com names.
# Targets ip1.lc1.nm.us.prestonhager.com (WAN NAT → ace :443). DNS-01 (_acme-challenge) is separate.
#
# Requires secrets/cloudflare.yaml in nix-secrets (dns-api-token or acme-env).
# Run on ace: sudo scripts/ace-cloudflare-dns-sync.sh [--dry-run]
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
ZONE_NAME="prestonhager.com"
CNAME_TARGET="ip1.lc1.nm.us.prestonhager.com"
DRY_RUN=false

# Keep in sync with nixos/containers/technitium-zones.nix aceHosted + public CNAME names.
HOSTS=(
  grafana cloud dns vault
  ai panel test.panel prometheus jellyfin wg metrics.wg zitadel git matrix
  spacetime test.sui faucet.test.sui indexer.test.sui factorio game
  lancache mc vpn serverdocs update
)

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

cd "$SECRETS"
plain="$(nix shell nixpkgs#sops --command sops -d secrets/cloudflare.yaml)"
TOKEN="$(printf '%s\n' "$plain" | awk -F= '/^  CLOUDFLARE_API_TOKEN=/{print $2; exit}')"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(printf '%s\n' "$plain" | awk '/^dns-api-token:/{print $2; exit}')"
fi
if [[ -z "$TOKEN" || "$TOKEN" == "REPLACE_ME" ]]; then
  echo "Cloudflare token missing or placeholder; run scripts/ace-cloudflare-secrets-setup.sh first." >&2
  exit 1
fi

cf_api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS -X "$method" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

zone_id="$(cf_api GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
  | jq -r '.result[0].id // empty')"
if [[ -z "$zone_id" ]]; then
  echo "Could not resolve Cloudflare zone id for ${ZONE_NAME}" >&2
  exit 1
fi

upsert_cname() {
  local name="$1"
  local fqdn="${name}.${ZONE_NAME}"
  local existing
  existing="$(cf_api GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${fqdn}" \
    | jq -r '.result[0] // empty')"

  local payload
  payload="$(jq -n \
    --arg type CNAME \
    --arg name "$fqdn" \
    --arg content "$CNAME_TARGET" \
    --argjson proxied false \
    '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: 1}')"

  if [[ -n "$existing" && "$existing" != "null" ]]; then
    local rid content proxied
    rid="$(jq -r '.id' <<<"$existing")"
    content="$(jq -r '.content' <<<"$existing")"
    proxied="$(jq -r '.proxied' <<<"$existing")"
    if [[ "$content" == "$CNAME_TARGET" && "$proxied" == "false" ]]; then
      echo "ok  ${fqdn} → ${CNAME_TARGET} (grey)"
      return 0
    fi
    echo "update ${fqdn} → ${CNAME_TARGET} (grey)"
    if [[ "$DRY_RUN" == true ]]; then
      return 0
    fi
    cf_api PATCH "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rid}" \
      -d "$payload" >/dev/null
  else
    echo "create ${fqdn} → ${CNAME_TARGET} (grey)"
    if [[ "$DRY_RUN" == true ]]; then
      return 0
    fi
    cf_api POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
      -d "$payload" >/dev/null
  fi
}

for host in "${HOSTS[@]}"; do
  upsert_cname "$host"
done

echo "Done. Public clients still need WAN NAT to ace :443; LAN uses Technitium split-horizon."
