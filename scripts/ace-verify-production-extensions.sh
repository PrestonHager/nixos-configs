#!/usr/bin/env bash
set -euo pipefail

panel=/pterodactyl/html

echo "=== view integrity ==="
for ext in dnsrecords portforward sociallogin; do
  view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
  extends=$(grep -c "@extends('layouts.admin')" "$view" 2>/dev/null || echo 0)
  echo "$ext: $(wc -c < "$view" | tr -d ' ') bytes, $extends @extends"
done

echo "=== controller smoke test ==="
podman exec pterodactyl sh -c 'cat > /tmp/verify-prod-ext.php <<'"'"'PHP'"'"'
<?php
require "/var/www/pterodactyl/vendor/autoload.php";
$app = require "/var/www/pterodactyl/bootstrap/app.php";
$app->make("Illuminate\Contracts\Console\Kernel")->bootstrap();
$user = \Pterodactyl\Models\User::query()->where("root_admin", 1)->first();
if ($user) {
  \Illuminate\Support\Facades\Auth::login($user);
}
foreach ([
  "dnsrecords" => "Pterodactyl\\Http\\Controllers\\Admin\\Extensions\\dnsrecords\\dnsrecordsExtensionController",
  "portforward" => "Pterodactyl\\Http\\Controllers\\Admin\\Extensions\\portforward\\portforwardExtensionController",
  "sociallogin" => "Pterodactyl\\Http\\Controllers\\Admin\\Extensions\\sociallogin\\socialloginExtensionController",
] as $name => $class) {
  try {
    $controller = $app->make($class);
    $response = $app->call([$controller, "index"]);
    $html = $response->render();
    echo "$name: " . strlen($html) . " bytes, box-title=" . substr_count($html, "box-title") . "\n";
  } catch (Throwable $e) {
    echo "$name: ERROR " . $e->getMessage() . "\n";
  }
}
PHP
php /tmp/verify-prod-ext.php' || true

echo "=== DB settings ==="
podman exec pterodactyl php -r '
require "/var/www/pterodactyl/vendor/autoload.php";
$app = require "/var/www/pterodactyl/bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
foreach (["dns_provider_mode","technitium_api_url","technitium_default_zone","update_on_allocation_change"] as $k) {
  echo "dns.$k=" . DB::table("dnsrecords_settings")->where("key", $k)->value("value") . "\n";
}
foreach (["enabled","router_host","router_ssh_user","dry_run"] as $k) {
  echo "pf.$k=" . DB::table("portforward_settings")->where("key", $k)->value("value") . "\n";
}
'

echo "=== HTTP assets ==="
for url in \
  "https://panel.prestonhager.com/assets/extensions/dnsrecords/icon.jpg" \
  "https://panel.prestonhager.com/assets/extensions/portforward/icon.jpg" \
  "https://panel.prestonhager.com/assets/extensions/sociallogin/icon.jpg" \
  "https://panel.prestonhager.com/assets/extensions/blueprint/logo.jpg"; do
  ct=$(curl -skI "$url" | awk -F': ' 'tolower($1)=="content-type" {print $2}' | tr -d '\r')
  magic=$(curl -sk "$url" | head -c 4 | xxd -p)
  echo "$url -> $ct magic=$magic"
done

echo "=== /admin/extensions (OAuth-protected, expect redirect) ==="
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://panel.prestonhager.com/admin/extensions")
echo "HTTP $code (302 to OAuth expected on production)"
