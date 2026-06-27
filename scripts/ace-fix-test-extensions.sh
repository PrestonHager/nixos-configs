#!/usr/bin/env bash
set -euo pipefail

panel=/home/prestonh/Projects/panel
prod=/pterodactyl/html
ext_root="$panel/app/BlueprintFramework/Extensions"
storage_ext="$panel/storage/extensions"
min_view_bytes=100

install -d -m 0755 -o prestonh -g users "$ext_root"
for ext in sociallogin dnsrecords portforward; do
  if [ -d "$panel/.blueprint/extensions/$ext/app" ] && [ ! -e "$ext_root/$ext" ]; then
    ln -sfn "../../../.blueprint/extensions/$ext/app" "$ext_root/$ext"
    chown -h prestonh:users "$ext_root/$ext"
    echo "linked app $ext"
  fi
done

install -d -m 2775 -o prestonh -g users "$storage_ext"
for ext in sociallogin dnsrecords portforward; do
  if [ -d "$panel/.blueprint/extensions/$ext/fs" ] && [ ! -e "$storage_ext/$ext" ]; then
    ln -sfn "../../.blueprint/extensions/$ext/fs" "$storage_ext/$ext"
    chown -h prestonh:users "$storage_ext/$ext"
    echo "linked storage $ext"
  fi
done

assets_ext="$panel/public/assets/extensions"
install -d -m 2775 -o prestonh -g users "$assets_ext"
for ext in blueprint sociallogin dnsrecords portforward; do
  if [ -d "$panel/.blueprint/extensions/$ext/assets" ] && [ ! -e "$assets_ext/$ext" ]; then
    ln -sfn "../../../.blueprint/extensions/$ext/assets" "$assets_ext/$ext"
    chown -h prestonh:users "$assets_ext/$ext"
    echo "linked public assets $ext"
  fi
done

for ext in sociallogin dnsrecords portforward; do
  ctrl="$panel/app/Http/Controllers/Admin/Extensions/$ext/${ext}ExtensionController.php"
  view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
  prod_ctrl="$prod/app/Http/Controllers/Admin/Extensions/$ext/${ext}ExtensionController.php"
  prod_view="$prod/resources/views/admin/extensions/$ext/index.blade.php"

  if [ ! -f "$ctrl" ] && [ -f "$prod_ctrl" ]; then
    install -d -m 0755 -o prestonh -g users "$(dirname "$ctrl")"
    cp -a "$prod_ctrl" "$ctrl"
    chown prestonh:users "$ctrl"
    echo "copied $ext controller"
  fi

  view_bytes=0
  if [ -f "$view" ]; then
    view_bytes=$(wc -c < "$view" | tr -d ' ')
  fi
  if [ -f "$prod_view" ] && { [ ! -f "$view" ] || [ "$view_bytes" -lt "$min_view_bytes" ]; }; then
    install -d -m 0755 -o prestonh -g users "$(dirname "$view")"
    cp -a "$prod_view" "$view"
    chown prestonh:users "$view"
    echo "copied $ext view (${view_bytes} -> $(wc -c < "$view" | tr -d ' ') bytes)"
  fi
done

for migration in "$prod"/database/migrations/2026_*.php; do
  [ -f "$migration" ] || continue
  base=$(basename "$migration")
  if [ ! -f "$panel/database/migrations/$base" ]; then
    cp -a "$migration" "$panel/database/migrations/$base"
    chown prestonh:users "$panel/database/migrations/$base"
    echo "copied migration $base"
  fi
done

podman exec -e HOME=/var/www/pterodactyl -e COMPOSER_HOME=/tmp/composer pterodactyl-test \
  sh -c 'cd /var/www/pterodactyl && composer dump-autoload -o'
podman exec pterodactyl-test php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl-test php /var/www/pterodactyl/artisan config:clear
podman exec pterodactyl-test php /var/www/pterodactyl/artisan view:clear

echo "=== verify views ==="
for ext in dnsrecords portforward sociallogin; do
  view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
  echo "$ext: $(wc -c < "$view" | tr -d ' ') bytes"
done

echo "=== verify migrations ==="
ls "$panel/database/migrations/" | grep 2026 || true

echo "=== controller smoke test ==="
podman exec pterodactyl-test php /tmp/test-ext-controllers.php 2>/dev/null || podman exec pterodactyl-test sh -c 'cat > /tmp/test-ext-controllers.php <<'"'"'PHP'"'"'
<?php
require "/var/www/pterodactyl/vendor/autoload.php";
$app = require "/var/www/pterodactyl/bootstrap/app.php";
$app->make("Illuminate\Contracts\Console\Kernel")->bootstrap();
foreach ([
  "dnsrecords" => "Pterodactyl\\Http\\Controllers\\Admin\\Extensions\\dnsrecords\\dnsrecordsExtensionController",
  "portforward" => "Pterodactyl\\Http\\Controllers\\Admin\\Extensions\\portforward\\portforwardExtensionController",
] as $name => $class) {
  try {
    $controller = $app->make($class);
    $response = $app->call([$controller, "index"]);
    echo $name . ": " . strlen($response->render()) . " bytes\n";
  } catch (Throwable $e) {
    echo $name . ": ERROR " . $e->getMessage() . "\n";
  }
}
PHP
php /tmp/test-ext-controllers.php'

echo "=== HTTP (login page first for CSRF) ==="
rm -f /tmp/pt-test.cookie
curl -sk -c /tmp/pt-test.cookie -b /tmp/pt-test.cookie "https://test.panel.prestonhager.com/auth/login" -o /dev/null
csrf=$(grep XSRF-TOKEN /tmp/pt-test.cookie | tail -1 | awk '{print $7}' | sed 's/%3D/=/g; s/%2F/\//g; s/%2B/+/g')
pass=$(awk -F= '/^password=/{print $2}' /var/lib/pterodactyl-test/admin-credentials)
curl -sk -c /tmp/pt-test.cookie -b /tmp/pt-test.cookie -X POST https://test.panel.prestonhager.com/auth/login \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H "X-XSRF-TOKEN: $csrf" \
  -d "{\"user\":\"admin\",\"password\":\"$pass\"}" | head -c 120
echo
for path in /admin/extensions /admin/extensions/dnsrecords /admin/extensions/portforward /admin/extensions/sociallogin; do
  code=$(curl -sk -b /tmp/pt-test.cookie -o /tmp/pt-out.html -w '%{http_code}' "https://test.panel.prestonhager.com$path")
  size=$(wc -c < /tmp/pt-out.html)
  echo "$code $size $path"
done
