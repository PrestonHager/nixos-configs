#!/usr/bin/env bash
# Revert production panel to stock Pterodactyl and install Blueprint framework.
# Run on ace as root. Does NOT touch test.panel.
set -euo pipefail

PANEL=/pterodactyl/html
STOCK_REPO="https://github.com/pterodactyl/panel.git"
STOCK_BRANCH="release/v1.11.11"
BLUEPRINT_URL="https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip"

echo "=== Reverting production panel to stock ${STOCK_BRANCH} ==="
cd "$PANEL"

git remote add upstream "$STOCK_REPO" 2>/dev/null || git remote set-url upstream "$STOCK_REPO"
git fetch upstream "$STOCK_BRANCH" --depth=1
git stash push -m "pre-stock-revert-$(date +%Y%m%d)" 2>/dev/null || true
git checkout -B "$STOCK_BRANCH" "upstream/$STOCK_BRANCH"
git remote set-url origin "$STOCK_REPO"

echo "=== Installing Composer dependencies ==="
podman exec -e COMPOSER_HOME=/tmp/composer pterodactyl sh -c \
  'cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader --no-interaction'

echo "=== Downloading and extracting Blueprint ==="
curl -fsSL -o /tmp/blueprint-release.zip "$BLUEPRINT_URL"
nix shell nixpkgs#unzip -c unzip -o /tmp/blueprint-release.zip -d "$PANEL"
chmod +x "$PANEL/blueprint.sh"
chown pterodactyl:pterodactyl "$PANEL/blueprint.sh" 2>/dev/null || true

echo "=== Running Blueprint installer ==="
cd "$PANEL"
# Non-interactive: blueprint.sh installs deps and applies framework patch
bash "$PANEL/blueprint.sh" -install 2>&1 || bash "$PANEL/blueprint.sh" 2>&1

echo "=== Post-install ==="
podman exec pterodactyl php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
podman exec pterodactyl php /var/www/pterodactyl/artisan view:clear
podman exec pterodactyl php /var/www/pterodactyl/artisan --version
ls -la "$PANEL/.blueprint" 2>/dev/null || ls -la "$PANEL/blueprint" 2>/dev/null || echo "check blueprint dirs"
command -v blueprint 2>/dev/null || ls -la /usr/local/bin/blueprint 2>/dev/null || true

echo "=== Done ==="
