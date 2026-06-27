<?php

if (!defined('LARAVEL_START')) {
    define('LARAVEL_START', microtime(true));
}

require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

$user = Pterodactyl\Models\User::query()->where('root_admin', 1)->first();
$server = Pterodactyl\Models\Server::query()->with('node')->find(14);
if (!$server) {
    echo "server 14 not found\n";
    exit(1);
}

auth()->login($user);
view()->share('errors', new Illuminate\Support\MessageBag());

$renderWithPath = function (string $path, callable $render) use ($app, $user): string {
    $request = Illuminate\Http\Request::create($path, 'GET');
    $request->setUserResolver(fn () => $user);
    $app->instance('request', $request);

    return $render();
};

$paths = [
    '/admin/servers/view/14' => null,
    '/extensions/dnsrecords/admin/servers/view/14' => 'dnsrecords',
    '/extensions/portforward/admin/servers/view/14' => 'portforward',
];

foreach ($paths as $path => $activeExt) {
    if ($path === '/admin/servers/view/14') {
        $html = $renderWithPath($path, function () use ($app, $server) {
            $aboutCtrl = $app->make(Pterodactyl\Http\Controllers\Admin\Servers\ServerViewController::class);

            return $app->call([$aboutCtrl, 'index'], ['server' => $server])->render();
        });
    } elseif ($activeExt === 'dnsrecords') {
        $html = $renderWithPath($path, function () use ($app, $server) {
            $ctrl = $app->make(Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers\DnsServerAdminController::class);

            return $app->call([$ctrl, 'show'], ['server' => $server->id])->render();
        });
    } else {
        $html = $renderWithPath($path, function () use ($app, $server) {
            $ctrl = $app->make(Pterodactyl\BlueprintFramework\Extensions\portforward\Http\Controllers\PortForwardServerAdminController::class);

            return $app->call([$ctrl, 'show'], ['server' => $server->id])->render();
        });
    }

    echo $path . ' bytes=' . strlen($html) . "\n";
    echo '  dnsrecords-server-nav: ' . (str_contains($html, 'dnsrecords-server-nav') ? 'YES' : 'NO') . "\n";
    echo '  portforward-server-nav: ' . (str_contains($html, 'portforward-server-nav') ? 'YES' : 'NO') . "\n";
    echo '  dns-init-call: ' . (str_contains($html, 'PterodactylPlugin_com_prestonhager_dns()') ? 'YES' : 'NO') . "\n";
    echo '  plugin-root-dns: ' . (str_contains($html, 'plugin-root-com-prestonhager-dns') ? 'YES' : 'NO') . "\n";
    echo '  plugin-root-pf: ' . (str_contains($html, 'plugin-root-portforward') ? 'YES' : 'NO') . "\n";
    if ($activeExt === 'dnsrecords') {
        echo '  dns-tab-active: ' . (preg_match('/id="dnsrecords-server-nav"[^>]*class="active"/', $html) ? 'YES' : 'NO') . "\n";
    }
    if ($activeExt === 'portforward') {
        echo '  pf-tab-active: ' . (preg_match('/id="portforward-server-nav"[^>]*class="active"/', $html) ? 'YES' : 'NO') . "\n";
    }
}

$kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);
foreach (['/extensions/dnsrecords/admin/servers/view/14', '/extensions/portforward/admin/servers/view/14'] as $path) {
    $request = Illuminate\Http\Request::create($path, 'GET');
    $request->setUserResolver(fn () => $user);
    auth()->login($user);
    $response = $kernel->handle($request);
    echo $path . ' http=' . $response->getStatusCode() . "\n";
    $kernel->terminate($request, $response);
}

// API smoke test for DNS records endpoint
$request = Illuminate\Http\Request::create('/extensions/dnsrecords/admin/servers/14/subdomain', 'GET');
$request->setUserResolver(fn () => $user);
auth()->login($user);
$response = $kernel->handle($request);
echo '/extensions/dnsrecords/admin/servers/14/subdomain http=' . $response->getStatusCode() . "\n";
$kernel->terminate($request, $response);
