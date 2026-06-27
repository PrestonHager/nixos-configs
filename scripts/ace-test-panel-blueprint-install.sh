#!/usr/bin/env bash
# One-shot Blueprint install for test.panel on ace. Run as root.
set -euo pipefail

panel=/home/prestonh/Projects/panel
dns_src=/etc/nixos/plugins/pterodactyl-dns-blueprint
pf_src=/etc/nixos/plugins/pterodactyl-portforward-blueprint
bp_url=https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip
sl_url=https://github.com/blueprint-community/extension-sociallogin/releases/download/1.2.0/sociallogin.blueprint

nix_panel() {
  nix shell \
    nixpkgs#yarn \
    nixpkgs#nodejs_22 \
    nixpkgs#bash \
    nixpkgs#unzip \
    nixpkgs#zip \
    nixpkgs#php83 \
    nixpkgs#gnused \
    nixpkgs#gnugrep \
    nixpkgs#gawk \
    nixpkgs#git \
    nixpkgs#findutils \
    nixpkgs#gnutar \
    nixpkgs#gzip \
    nixpkgs#coreutils \
    --command env HOME=/home/prestonh TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 "$@"
}

echo "=== Cleaning test panel Blueprint state ==="
rm -f /var/lib/pterodactyl-test/blueprint-installed
rm -rf \
  "$panel/.blueprint" "$panel/blueprint" "$panel/blueprint.sh" \
  "$panel/.blueprintrc" "$panel/node_modules" "$panel/sociallogin.blueprint" \
  2>/dev/null || true

echo "=== Installing Blueprint framework ==="
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$bp_url" -o "$tmp/release.zip"
nix shell nixpkgs#unzip -c unzip -o "$tmp/release.zip" -d "$panel"
chown -R prestonh:users "$panel"
cat > "$panel/.blueprintrc" <<'EOF'
WEBUSER="prestonh"
OWNERSHIP="prestonh:users"
USERSHELL="/bin/sh"
TECHNITIUM_API_URL="https://dns.prestonhager.com"
EOF
chown prestonh:users "$panel/.blueprintrc"
chmod +x "$panel/blueprint.sh"
chown prestonh:users "$panel/blueprint.sh"
install -d -m 0755 -o prestonh -g users "$panel/.blueprint/extensions/blueprint/private/debug"
install -m 0644 /dev/null "$panel/.blueprint/extensions/blueprint/private/debug/logs.txt"
chown prestonh:users "$panel/.blueprint/extensions/blueprint/private/debug/logs.txt"

if [ -d "$panel/blueprint" ]; then
  install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
  mv "$panel/blueprint" "$panel/.blueprint/blueprint"
  chown -R prestonh:users "$panel/.blueprint/blueprint"
fi

echo "=== yarn install ==="
nix_panel bash -c "cd '$panel' && yarn install"

echo "=== blueprint.sh framework ==="
nix_panel env BLUEPRINT_ENVIRONMENT=ci bash -c "cd '$panel' && bash ./blueprint.sh"

echo "=== sociallogin ==="
curl -fsSL "$sl_url" -o "$tmp/sociallogin.blueprint"
cp "$tmp/sociallogin.blueprint" "$panel/sociallogin.blueprint"
chown prestonh:users "$panel/sociallogin.blueprint"
nix_panel bash -c "cd '$panel' && rm -f .blueprint/lock && bash ./blueprint.sh -install sociallogin"
rm -f "$panel/sociallogin.blueprint"

install_dev_ext() {
  install -d -m 0755 -o prestonh -g users "$panel/.blueprint/dev"
  rm -rf "$panel/.blueprint/dev/"*
  cp -a "$1/." "$panel/.blueprint/dev/"
  chown -R prestonh:users "$panel/.blueprint/dev"
  nix_panel bash -c "cd '$panel' && rm -f .blueprint/lock && bash ./blueprint.sh -install '[developer-build]'"
}

echo "=== dnsrecords ==="
install_dev_ext "$dns_src"
echo "=== portforward ==="
install_dev_ext "$pf_src"

echo "=== frontend build ==="
nix_panel env NODE_ENV=production NODE_OPTIONS=--openssl-legacy-provider \
  bash -c "cd '$panel' && yarn build:production"

chown -R prestonh:users "$panel"

echo "=== composer + artisan ==="
podman exec -e COMPOSER_HOME=/tmp/composer pterodactyl-test \
  sh -c 'cd /var/www/pterodactyl && rm -rf vendor && composer install --no-dev --optimize-autoloader'
podman exec pterodactyl-test php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan db:seed --class=BlueprintSeeder --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan config:clear
podman exec pterodactyl-test php /var/www/pterodactyl/artisan view:clear

echo "blueprint+sociallogin+dnsrecords+portforward" > /var/lib/pterodactyl-test/blueprint-installed
chown pterodactyl:pterodactyl /var/lib/pterodactyl-test/blueprint-installed
systemctl restart pterodactyl-test-blueprint-extensions-configure.service
systemctl restart pterodactyl-test-sso-configure.service
echo "=== Manual Blueprint install complete ==="
