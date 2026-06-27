#!/usr/bin/env bash
# Create or update Cloudflare API token in nix-secrets (ACME DNS-01 + optional DNS sync).
# Run on ace as root or with sudo. Token from arg or CLOUDFLARE_API_TOKEN env.
set -euo pipefail

export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
SECRETS=/home/prestonh/nixos-secrets
# Not secret; matches homelab.caddy.cloudflareAcme.accountId on ace.
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-12f5428fd594b9e9c2eaadfdd0fdc857}"
TOKEN="${1:-${CLOUDFLARE_API_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
  echo "Usage: $0 <cloudflare-api-token>" >&2
  echo "   or: CLOUDFLARE_API_TOKEN=... $0" >&2
  exit 1
fi

cd "$SECRETS"
git pull --ff-only origin main

cat > secrets/cloudflare.yaml <<EOF
# Plain (not encrypted): account id for scripts/docs; caddy-dns/cloudflare does not need it.
account-id: ${ACCOUNT_ID}

acme-env: |
  CLOUDFLARE_API_TOKEN=${TOKEN}

dns-api-token: ${TOKEN}
EOF

nix shell nixpkgs#sops --command sops --encrypt \
  --encrypted-regex '^(acme-env|dns-api-token)$' \
  --in-place secrets/cloudflare.yaml

echo "=== cloudflare secret keys (redacted) ==="
nix shell nixpkgs#sops --command sops -d secrets/cloudflare.yaml \
  | sed 's/=.*/=***REDACTED***/'

git add secrets/cloudflare.yaml
if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "$(cat <<'EOF'
Add Cloudflare API token for Caddy DNS-01 and DNS sync.

EOF
)"
  git push origin main
fi

echo "On ace, update flake input and rebuild:"
echo "  cd /etc/nixos && nix flake update nix-secrets && sudo nixos-rebuild switch --flake .#ace"
