#!/usr/bin/env bash
for url in \
  https://test.panel.prestonhager.com/assets/extensions/dnsrecords/icon.jpg \
  https://test.panel.prestonhager.com/assets/extensions/portforward/icon.jpg \
  https://test.panel.prestonhager.com/assets/extensions/sociallogin/icon.jpg \
  https://test.panel.prestonhager.com/assets/extensions/blueprint/logo.jpg \
  https://test.panel.prestonhager.com/assets/extensions/blueprint/promo-blur.jpg
do
  echo "=== $url ==="
  curl -skI "$url" | head -5
  curl -sk "$url" | head -c 4 | xxd -p
  echo
done
