<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers;

use Illuminate\Contracts\View\View;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Models\Server;

class DnsServerAdminController extends Controller
{
    public function show(int $server): View
    {
        $model = Server::query()->findOrFail($server);

        return view()->file(
            base_path('.blueprint/extensions/dnsrecords/views/admin/server.blade.php'),
            [
                'server' => $model,
                'apiBase' => '/extensions/dnsrecords/admin/servers/' . $model->id,
            ],
        );
    }
}
