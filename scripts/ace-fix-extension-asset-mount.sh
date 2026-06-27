#!/usr/bin/env bash
set -euo pipefail

panel=/home/prestonh/Projects/panel
mount=/pterodactyl-test/html
legacy=/pterodactyl-test/public

install -d -m 0755 "$mount"
if mountpoint -q "$legacy"; then
  umount "$legacy"
  echo "unmounted legacy $legacy"
fi
if ! mountpoint -q "$mount"; then
  mount --bind "$panel" "$mount"
  echo "mounted $panel -> $mount"
fi

assets_ext="$panel/public/assets/extensions"
for ext in blueprint sociallogin dnsrecords portforward; do
  target="$panel/.blueprint/extensions/$ext/assets"
  [ -d "$target" ] || continue
  rm -f "$assets_ext/$ext"
  ln -sfn "../../../.blueprint/extensions/$ext/assets" "$assets_ext/$ext"
  chown -h prestonh:users "$assets_ext/$ext"
  echo "linked $ext -> $(readlink "$assets_ext/$ext")"
done

systemctl reload caddy 2>/dev/null || systemctl restart caddy

urls=(
  "https://test.panel.prestonhager.com/assets/extensions/dnsrecords/icon.jpg"
  "https://test.panel.prestonhager.com/assets/extensions/portforward/icon.jpg"
  "https://test.panel.prestonhager.com/assets/extensions/sociallogin/icon.jpg"
  "https://test.panel.prestonhager.com/assets/extensions/blueprint/logo.jpg"
  "https://test.panel.prestonhager.com/assets/extensions/blueprint/promo-blur.jpg"
)

echo "=== verification ==="
for url in "${urls[@]}"; do
  ct=$(curl -skI "$url" | awk -F': ' 'tolower($1)=="content-type" {print $2}' | tr -d '\r')
  magic=$(curl -sk "$url" | head -c 4 | xxd -p)
  echo "$url"
  echo "  content-type: $ct"
  echo "  magic: $magic"
done

namei -l "$mount/public/assets/extensions/dnsrecords/icon.jpg" | tail -3
