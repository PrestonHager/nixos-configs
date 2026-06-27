#!/usr/bin/env bash
# Diagnose Nextcloud OIDC admin group mapping on ace.
set -euo pipefail

echo "=== Nextcloud user_oidc provider ==="
podman exec -u www-data nextcloud php /var/www/html/occ user_oidc:provider zitadel

echo
echo "=== prestonh user info ==="
podman exec -u www-data nextcloud php /var/www/html/occ user:info prestonh

echo
echo "=== admin group members ==="
podman exec -u www-data nextcloud php /var/www/html/occ group:info admin

echo
echo "=== Zitadel prestonh grants (Home Lab project) ==="
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT u.username, ug.roles FROM projections.users14 u
   JOIN projections.user_grants5 ug ON u.id = ug.user_id
   WHERE u.username IN ('prestonh','admin@prestonhager.com')
     AND ug.project_id = '376196450586990901';"

echo
echo "=== Zitadel *Groups actions ==="
podman exec zitadel-db psql -U zitadel -d zitadel -c \
  "SELECT id, name FROM projections.actions3 WHERE name LIKE '%Groups%';"

echo
echo "=== Token groups claim test ==="
cd /etc/nixos
nix shell nixpkgs#nodejs_22 -c node scripts/zitadel-nextcloud-userinfo-test.js || true
