#!/usr/bin/env bash
set -euo pipefail

cd /etc/nixos
git fetch origin dell-poweredge-r730xd
git checkout dell-poweredge-r730xd
git pull --ff-only origin dell-poweredge-r730xd

nixos-rebuild switch --flake .#ace

systemctl restart pterodactyl-blueprint-extensions-configure.service
systemctl restart pterodactyl-test-blueprint-install.service || systemctl start pterodactyl-test-blueprint-install.service
systemctl restart pterodactyl-test-pod-network-check.service || systemctl start pterodactyl-test-pod-network-check.service

echo "=== VERIFY PROD SETTINGS ==="
podman exec -e HOME=/var/www/pterodactyl pterodactyl \
  php /var/www/pterodactyl/artisan tinker --execute='var_export(DB::table("portforward_settings")->where("key","enabled")->value("value")); echo "\n";'

echo "=== VERIFY TEST HTTP ==="
curl -sk -o /dev/null -w "test.panel HTTP %{http_code}\n" https://test.panel.prestonhager.com/
podman exec pterodactyl-test redis-cli -h 127.0.0.1 ping || echo "redis still broken"
