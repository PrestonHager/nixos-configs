#!/usr/bin/env bash
set -euo pipefail

panel=/home/prestonh/Projects/panel
release_url=https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip

test -f "$panel/artisan" || { echo "panel not stock — run stock reset first" >&2; exit 1; }

nix shell nixpkgs#nodejs_22 nixpkgs#yarn nixpkgs#php83 nixpkgs#zip nixpkgs#unzip nixpkgs#curl -c bash <<'INNER'
set -euo pipefail
panel=/home/prestonh/Projects/panel
release_url=https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$release_url" -o "$tmp/release.zip"
unzip -o "$tmp/release.zip" -d "$panel"
chmod +x "$panel/blueprint.sh"
chown prestonh:users "$panel/blueprint.sh" 2>/dev/null || true

install -d -m 0755 -o prestonh -g users /home/prestonh/.cache/yarn-blueprint-test
install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
if [ -d "$panel/blueprint" ]; then
  rm -rf "$panel/.blueprint/blueprint"
  mv "$panel/blueprint" "$panel/.blueprint/blueprint"
fi

cd "$panel"
runuser -u prestonh -- env HOME=/home/prestonh TERM=xterm YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test yarn install
env HOME=/home/prestonh TERM=xterm YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test bash "$panel/blueprint.sh"

mkdir -p "$panel/.blueprint/dev"
cp -a /etc/nixos/plugins/pterodactyl-dns-blueprint/. "$panel/.blueprint/dev/"
chown -R prestonh:users "$panel/.blueprint/dev"
runuser -u prestonh -- env HOME=/home/prestonh TERM=xterm bash "$panel/blueprint.sh" -install '[developer-build]' || true
INNER

chown -R prestonh:users "$panel"
podman exec pterodactyl-test sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'
podman exec pterodactyl-test php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan config:clear
systemctl restart podman-pterodactyl-test.service
sleep 5
curl -sS -o /dev/null -w "test_panel=%{http_code}\n" https://test.panel.prestonhager.com/
ls "$panel/.blueprint/extensions/" 2>/dev/null || true
echo "upstream-blueprint" > /var/lib/pterodactyl-test/blueprint-installed
