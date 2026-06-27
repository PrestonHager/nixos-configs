<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Http\Controllers;

use Illuminate\Contracts\View\View;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Services;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Com\Prestonhager\PortForward\Support\NodeIpResolver;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginException;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Models\Server;

class PortForwardServerAdminController extends Controller
{
    public function show(int $server): View
    {
        $model = Server::query()->with('node')->findOrFail($server);
        $context = PluginContext::make();
        $settings = $context->config()->all();

        $nodeTarget = null;
        $nodeTargetError = null;

        try {
            $nodeTarget = (new NodeIpResolver($context, Services::config($context)))->resolve($model);
        } catch (PluginException $e) {
            $nodeTargetError = $e->getMessage();
        }

        return view()->file(
            base_path('.blueprint/extensions/portforward/views/admin/server.blade.php'),
            [
                'server' => $model,
                'apiBase' => '/extensions/portforward/admin/servers/' . $model->id,
                'settings' => $settings,
                'nodeTarget' => $nodeTarget,
                'nodeTargetError' => $nodeTargetError,
            ],
        );
    }
}
