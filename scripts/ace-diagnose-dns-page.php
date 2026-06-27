<?php

if (!defined('LARAVEL_START')) {
    define('LARAVEL_START', microtime(true));
}

require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

$user = Pterodactyl\Models\User::query()->where('root_admin', 1)->first();
auth()->login($user);
$kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);

foreach (['/subdomain', '/srv-profiles', '/records'] as $suffix) {
    $path = '/extensions/dnsrecords/admin/servers/14' . $suffix;
    $request = Illuminate\Http\Request::create($path, 'GET');
    $request->setUserResolver(fn () => $user);
    $response = $kernel->handle($request);
    $body = $response->getContent();
    echo $path . ' status=' . $response->getStatusCode() . ' bytes=' . strlen($body) . "\n";
    echo substr($body, 0, 200) . "\n---\n";
    $kernel->terminate($request, $response);
}

$request = Illuminate\Http\Request::create('/extensions/dnsrecords/admin/servers/view/14', 'GET');
$request->setUserResolver(fn () => $user);
$response = $kernel->handle($request);
$html = $response->getContent();
echo "page status=" . $response->getStatusCode() . "\n";
echo "has plugin root: " . (str_contains($html, 'plugin-root-com-prestonhager-dns') ? 'yes' : 'no') . "\n";
echo "has init call: " . (str_contains($html, 'PterodactylPlugin_com_prestonhager_dns()') ? 'yes' : 'no') . "\n";
echo "has dns-admin.js: " . (str_contains($html, '/extensions/dnsrecords/dns-admin.js') ? 'yes' : 'no') . "\n";
if (preg_match('/<div id="plugin-root-com-prestonhager-dns"[^>]*>.*?<\/div>/s', $html, $m)) {
    echo "plugin root inner: " . json_encode($m[0]) . "\n";
}
$pos = strpos($html, 'plugin-root-com-prestonhager-dns');
if ($pos !== false) {
    echo "context snippet:\n" . substr($html, $pos, 900) . "\n";
}
$kernel->terminate($request, $response);
