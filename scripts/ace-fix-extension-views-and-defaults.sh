#!/usr/bin/env bash
set -euo pipefail

panel=/home/prestonh/Projects/panel
dns_src=/etc/nixos/plugins/pterodactyl-dns-blueprint/admin/view.blade.php
pf_src=/etc/nixos/plugins/pterodactyl-portforward-blueprint/admin/view.blade.php

for ext in dnsrecords portforward; do
  view="$panel/resources/views/admin/extensions/$ext/index.blade.php"
  src="$dns_src"
  [ "$ext" = "portforward" ] && src="$pf_src"
  install -d -m 0755 -o prestonh -g users "$(dirname "$view")"
  cp -a "$src" "$view"
  chown prestonh:users "$view"
  echo "installed $ext view from plugin source ($(wc -c < "$view" | tr -d ' ') bytes, $(grep -c "@extends('layouts.admin')" "$view") extends)"
done

podman exec pterodactyl-test php /var/www/pterodactyl/artisan view:clear

# Apply homelab defaults (mirrors production + pterodactyl-test-blueprint-extensions-configure.nix)
live_nat=0
[ -f /pterodactyl/secrets/pterodactyl-router-ssh-key ] && live_nat=1
dry_run=$([ "$live_nat" -eq 1 ] && echo false || echo true)

podman exec pterodactyl-test sh -c "cat > /tmp/configure-extensions.php <<'PHP'
<?php
require \"/var/www/pterodactyl/vendor/autoload.php\";
\$app = require \"/var/www/pterodactyl/bootstrap/app.php\";
\$app->make(\"Illuminate\\\\Contracts\\\\Console\\\\Kernel\")->bootstrap();

use Pterodactyl\\BlueprintFramework\\Extensions\\portforward\\Models\\PortForwardSetting;
use Pterodactyl\\BlueprintFramework\\Extensions\\dnsrecords\\Models\\DnsExtensionSetting;

\$portforward = [
  'enabled' => true,
  'router_host' => '192.168.5.1',
  'router_ssh_user' => 'pterofwd',
  'wan_interface' => 'GigabitEthernet0/0',
  'dry_run' => $dry_run,
  'auto_forward_on_install' => false,
  'auto_remove_on_delete' => true,
  'allowed_port_min' => 1024,
  'allowed_port_max' => 65535,
  'blocked_ports' => [22, 80, 443, 3380],
  'node_ip_map' => ['1' => '192.168.5.6', '2' => '192.168.5.7'],
  'max_mappings_per_server' => 8,
];
foreach (\$portforward as \$key => \$value) {
  PortForwardSetting::query()->updateOrCreate(['key' => \$key], ['value' => \$value]);
}

\$dns = [
  'dns_provider_mode' => 'technitium',
  'technitium_api_url' => 'http://host.containers.internal:5380',
  'technitium_default_zone' => 'prestonhager.com',
  'dry_run' => false,
  'auto_provision_enabled' => true,
  'update_on_allocation_change' => true,
];
foreach (\$dns as \$key => \$value) {
  DnsExtensionSetting::query()->updateOrCreate(['key' => \$key], ['value' => \$value]);
}
echo \"configured\\n\";
PHP
php /tmp/configure-extensions.php"

echo "=== verify views ==="
for ext in dnsrecords portforward; do
  f="$panel/resources/views/admin/extensions/$ext/index.blade.php"
  echo "$ext: $(grep -c "@extends('layouts.admin')" "$f") extends, $(grep -c 'box-title' "$f") box-title"
done

echo "=== verify settings ==="
podman exec pterodactyl-test mariadb -upterodactyl_test -p$(grep '^DB_PASSWORD=' "$panel/.env" | cut -d= -f2) panel_test -e "SELECT \`key\` FROM dnsrecords_settings ORDER BY 1; SELECT \`key\` FROM portforward_settings ORDER BY 1;" 2>/dev/null
