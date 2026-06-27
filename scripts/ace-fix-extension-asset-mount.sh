#!/usr/bin/env bash
set -euo pipefail

panel=/home/prestonh/Projects/panel
public=/pterodactyl-test/public
blueprint=/pterodactyl-test/.blueprint

# Tear down full-panel mount if a prior fix attempt left it in place.
if mountpoint -q /pterodactyl-test/html; then
  umount /pterodactyl-test/html || true
fi

install -d -m 0755 /pterodactyl-test "$public" "$blueprint"
if ! mountpoint -q "$public"; then
  mount --bind "$panel/public" "$public"
  echo "mounted public"
fi
if ! mountpoint -q "$blueprint"; then
  mount --bind "$panel/.blueprint" "$blueprint"
  echo "mounted blueprint"
fi

assets_ext="$panel/public/assets/extensions"
for ext in blueprint sociallogin dnsrecords portforward; do
  target="$panel/.blueprint/extensions/$ext/assets"
  [ -d "$target" ] || continue
  rm -f "$assets_ext/$ext"
  ln -sfn "../../../.blueprint/extensions/$ext/assets" "$assets_ext/$ext"
  chown -h prestonh:users "$assets_ext/$ext"
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

namei -l "$public/assets/extensions/dnsrecords/icon.jpg" | tail -4
