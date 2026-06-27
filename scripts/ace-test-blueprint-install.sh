#!/usr/bin/env bash
set -euo pipefail

panel=/home/prestonh/Projects/panel
fork_dir=/var/lib/pterodactyl-test/blueprint-framework

test -f "$panel/artisan" || { echo "panel not stock — run stock reset first" >&2; exit 1; }

nix shell nixpkgs#nodejs_22 nixpkgs#yarn nixpkgs#php83 nixpkgs#zip nixpkgs#unzip nixpkgs#git -c bash <<'INNER'
set -euo pipefail
panel=/home/prestonh/Projects/panel
fork_dir=/var/lib/pterodactyl-test/blueprint-framework

git -C "$fork_dir" fetch origin feat/prestonhager-plugin-manager --depth=1
git -C "$fork_dir" checkout feat/prestonhager-plugin-manager
git -C "$fork_dir" reset --hard origin/feat/prestonhager-plugin-manager

archive="$fork_dir/release-overlay.zip"
git -C "$fork_dir" archive --format=zip HEAD -o "$archive"
unzip -o "$archive" -d "$panel"
chmod +x "$panel/blueprint.sh"
chown prestonh:users "$panel/blueprint.sh" "$panel/blueprint.sh" 2>/dev/null || true

install -d -m 0755 -o prestonh -g users /home/prestonh/.cache/yarn-blueprint-test
install -d -m 0755 -o prestonh -g users "$panel/.blueprint"
if [ -d "$panel/blueprint" ]; then
  rm -rf "$panel/.blueprint/blueprint"
  mv "$panel/blueprint" "$panel/.blueprint/blueprint"
fi

cd "$panel"
runuser -u prestonh -- env HOME=/home/prestonh TERM=xterm YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test yarn install
env HOME=/home/prestonh TERM=xterm YARN_CACHE_FOLDER=/home/prestonh/.cache/yarn-blueprint-test BLUEPRINT_ENVIRONMENT=ci bash "$panel/blueprint.sh"

mkdir -p "$panel/.blueprint/dev"
cp -a /etc/nixos/plugins/pterodactyl-dns-blueprint/. "$panel/.blueprint/dev/"
chown -R prestonh:users "$panel/.blueprint/dev"
runuser -u prestonh -- env HOME=/home/prestonh TERM=xterm BLUEPRINT_ENVIRONMENT=ci bash "$panel/blueprint.sh" -build
runuser -u prestonh -- env HOME=/home/prestonh TERM=xterm bash "$panel/blueprint.sh" -install dnsrecords || true
INNER

chown -R prestonh:users "$panel"
podman exec pterodactyl-test sh -c 'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader'
podman exec pterodactyl-test php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan config:clear
systemctl restart podman-pterodactyl-test.service
sleep 5
curl -sS -o /dev/null -w "test_panel=%{http_code}\n" https://test.panel.prestonhager.com/
ls "$panel/.blueprint/extensions/" 2>/dev/null || true
echo "fork:$(git -C $fork_dir rev-parse HEAD)" > /var/lib/pterodactyl-test/blueprint-fork-installed
