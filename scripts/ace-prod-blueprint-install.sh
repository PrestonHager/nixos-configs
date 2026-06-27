#!/usr/bin/env bash
set -euo pipefail
PANEL=/pterodactyl/html
BLUEPRINT_URL="https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip"
curl -fsSL -o /tmp/blueprint-release.zip "$BLUEPRINT_URL"
nix shell nixpkgs#unzip -c unzip -o /tmp/blueprint-release.zip -d "$PANEL"
chmod +x "$PANEL/blueprint.sh"
cd "$PANEL"
bash blueprint.sh -install
podman exec pterodactyl php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
podman exec pterodactyl php /var/www/pterodactyl/artisan view:clear
systemctl restart pterodactyl-patch-header-auth.service
echo DONE
