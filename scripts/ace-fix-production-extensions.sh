#!/usr/bin/env bash
set -euo pipefail

panel=/pterodactyl/html
ext_root="$panel/app/BlueprintFramework/Extensions"
storage_ext="$panel/storage/extensions"

install -d -m 0755 -o pterodactyl -g pterodactyl "$ext_root"
for ext in sociallogin dnsrecords portforward; do
  if [ -d "$panel/.blueprint/extensions/$ext/app" ] && [ ! -e "$ext_root/$ext" ]; then
    ln -sfn "../../../.blueprint/extensions/$ext/app" "$ext_root/$ext"
    chown -h pterodactyl:pterodactyl "$ext_root/$ext"
    echo "linked app $ext"
  fi
done

install -d -m 2775 -o pterodactyl -g pterodactyl "$storage_ext"
for ext in sociallogin dnsrecords portforward; do
  if [ -d "$panel/.blueprint/extensions/$ext/fs" ] && [ ! -e "$storage_ext/$ext" ]; then
    ln -sfn "../../.blueprint/extensions/$ext/fs" "$storage_ext/$ext"
    chown -h pterodactyl:pterodactyl "$storage_ext/$ext"
    echo "linked storage $ext"
  fi
done

assets_ext="$panel/public/assets/extensions"
install -d -m 2775 -o pterodactyl -g pterodactyl "$assets_ext"
for ext in blueprint sociallogin dnsrecords portforward; do
  target="$panel/.blueprint/extensions/$ext/assets"
  [ -d "$target" ] || continue
  rm -f "$assets_ext/$ext"
  ln -sfn "../../../.blueprint/extensions/$ext/assets" "$assets_ext/$ext"
  chown -h pterodactyl:pterodactyl "$assets_ext/$ext"
  echo "linked public assets $ext"
done

for ext in sociallogin dnsrecords portforward; do
  ctrl="$panel/app/Http/Controllers/Admin/Extensions/$ext/${ext}ExtensionController.php"
  view="$panel/resources/views/admin/extensions/$ext/index.blade.php"

  src_ctrl=""
  src_view=""
  case "$ext" in
    dnsrecords)
      src_ctrl=/etc/nixos/plugins/pterodactyl-dns-blueprint/admin/controller.php
      src_view=/etc/nixos/plugins/pterodactyl-dns-blueprint/admin/view.blade.php
      ;;
    portforward)
      src_ctrl=/etc/nixos/plugins/pterodactyl-portforward-blueprint/admin/controller.php
      src_view=/etc/nixos/plugins/pterodactyl-portforward-blueprint/admin/view.blade.php
      ;;
  esac

  if [ -n "$src_ctrl" ] && [ -f "$src_ctrl" ] && [ ! -f "$ctrl" ]; then
    install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$ctrl")"
    cp -a "$src_ctrl" "$ctrl"
    chown pterodactyl:pterodactyl "$ctrl"
    echo "installed $ext controller from plugin source"
  fi

  if [ -n "$src_view" ] && [ -f "$src_view" ]; then
    extends=$(grep -c "@extends('layouts.admin')" "$view" 2>/dev/null || echo 0)
    if [ ! -f "$view" ] || [ "$extends" -ne 1 ]; then
      install -d -m 0755 -o pterodactyl -g pterodactyl "$(dirname "$view")"
      cp -a "$src_view" "$view"
      chown pterodactyl:pterodactyl "$view"
      echo "installed $ext view from plugin source"
    fi
  fi
done

for src_dir in \
  /etc/nixos/plugins/pterodactyl-dns-blueprint/database/migrations \
  /etc/nixos/plugins/pterodactyl-portforward-blueprint/database/migrations; do
  [ -d "$src_dir" ] || continue
  for migration in "$src_dir"/*.php; do
    [ -f "$migration" ] || continue
    base=$(basename "$migration")
    if [ ! -f "$panel/database/migrations/$base" ]; then
      cp -a "$migration" "$panel/database/migrations/$base"
      chown pterodactyl:pterodactyl "$panel/database/migrations/$base"
      echo "copied migration $base"
    fi
  done
done

podman exec -e HOME=/var/www/pterodactyl -e COMPOSER_HOME=/tmp/composer pterodactyl \
  sh -c 'cd /var/www/pterodactyl && composer dump-autoload -o'
podman exec pterodactyl php /var/www/pterodactyl/artisan migrate --force
podman exec pterodactyl php /var/www/pterodactyl/artisan config:clear
podman exec pterodactyl php /var/www/pterodactyl/artisan view:clear

systemctl restart pterodactyl-blueprint-extensions-configure.service

echo "=== verify views ==="
for ext in dnsrecords portforward sociallogin; do
  view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
  extends=$(grep -c "@extends('layouts.admin')" "$view" 2>/dev/null || echo 0)
  echo "$ext: $(wc -c < "$view" | tr -d ' ') bytes, $extends extends"
done

echo "=== verify asset symlinks ==="
for ext in blueprint sociallogin dnsrecords portforward; do
  f="$panel/public/assets/extensions/$ext"
  if [ "$ext" = "blueprint" ]; then
    f="$f/logo.jpg"
  else
    f="$f/icon.jpg"
  fi
  echo "$ext: $([ -f "$f" ] && echo OK || echo MISSING) $f"
done

echo "=== verify settings ==="
podman exec pterodactyl php /var/www/pterodactyl/artisan tinker --execute="
foreach (['dnsrecords_settings','portforward_settings'] as \$t) {
  echo \$t . ': ' . implode(', ', DB::table(\$t)->orderBy('key')->pluck('key')->all()) . PHP_EOL;
}
" 2>/dev/null || true

echo "=== HTTP asset check ==="
for url in \
  "https://panel.prestonhager.com/assets/extensions/dnsrecords/icon.jpg" \
  "https://panel.prestonhager.com/assets/extensions/portforward/icon.jpg" \
  "https://panel.prestonhager.com/assets/extensions/sociallogin/icon.jpg" \
  "https://panel.prestonhager.com/assets/extensions/blueprint/logo.jpg"; do
  ct=$(curl -skI "$url" | awk -F': ' 'tolower($1)=="content-type" {print $2}' | tr -d '\r')
  magic=$(curl -sk "$url" | head -c 4 | xxd -p 2>/dev/null || echo n/a)
  echo "$url -> $ct magic=$magic"
done
