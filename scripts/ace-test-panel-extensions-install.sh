#!/usr/bin/env bash
set -euo pipefail
panel=/home/prestonh/Projects/panel
dns_src=/etc/nixos/plugins/pterodactyl-dns-blueprint
pf_src=/etc/nixos/plugins/pterodactyl-portforward-blueprint

nix_panel() {
  nix shell \
    nixpkgs#yarn nixpkgs#nodejs_22 nixpkgs#bash nixpkgs#unzip nixpkgs#zip \
    nixpkgs#php83 nixpkgs#gnused nixpkgs#gnugrep nixpkgs#gawk nixpkgs#git \
    nixpkgs#findutils nixpkgs#coreutils \
    --command env HOME=/home/prestonh BLUEPRINT_ENVIRONMENT=ci TERM=dumb LC_ALL=C.UTF-8 LANG=C.UTF-8 "$@"
}

install_dev_ext() {
  install -d -m 0755 "$panel/.blueprint/dev"
  rm -rf "$panel/.blueprint/dev/"*
  cp -a "$1/." "$panel/.blueprint/dev/"
  chown -R prestonh:users "$panel/.blueprint/dev"
  nix_panel bash -c "cd '$panel' && rm -f .blueprint/lock && yes n | bash ./blueprint.sh -bash -install '[developer-build]'"
}

if [ ! -f "$panel/.blueprint/extensions/blueprint/private/extensionfs.php" ]; then
  echo "Copying blueprint core extension from production..."
  rm -rf "$panel/.blueprint/extensions/blueprint"
  cp -a /pterodactyl/html/.blueprint/extensions/blueprint "$panel/.blueprint/extensions/"
  cp -a /pterodactyl/html/.blueprint/assets "$panel/.blueprint/"
  chown -R prestonh:users "$panel/.blueprint"
fi

echo "=== dnsrecords ==="
install_dev_ext "$dns_src"
echo "=== portforward ==="
install_dev_ext "$pf_src"

nix_panel env NODE_ENV=production NODE_OPTIONS=--openssl-legacy-provider \
  bash -c "cd '$panel' && yarn build:production"

podman exec pterodactyl-test php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan db:seed --class=BlueprintSeeder --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan config:clear
podman exec pterodactyl-test php /var/www/pterodactyl/artisan view:clear

echo "blueprint+sociallogin+dnsrecords+portforward" > /var/lib/pterodactyl-test/blueprint-installed
chown pterodactyl:pterodactyl /var/lib/pterodactyl-test/blueprint-installed
systemctl restart pterodactyl-test-blueprint-extensions-configure.service
systemctl restart pterodactyl-test-sso-configure.service
ls "$panel/.blueprint/extensions/"
