<?php

namespace Pterodactyl\Http\Controllers\Admin\Extensions\minecrafttools;

use Illuminate\Contracts\View\Factory as ViewFactory;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;
use Pterodactyl\BlueprintFramework\Libraries\ExtensionLibrary\Admin\BlueprintAdminLibrary;
use Pterodactyl\Http\Controllers\Controller;

class minecrafttoolsExtensionController extends Controller
{
    public function __construct(
        private ViewFactory $view,
        private BlueprintAdminLibrary $blueprint,
    ) {
    }

    public function index(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.index', [
            'root' => '/admin/extensions/minecraft-tools',
            'blueprint' => $this->blueprint,
        ]);
    }

    public function plugins(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.plugins');
    }

    public function versions(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.versions');
    }

    public function players(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.players');
    }

    public function modpacks(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.modpacks');
    }

    public function config(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.config');
    }

    public function icon(): View
    {
        return $this->view->make('admin.extensions.minecraft-tools.icon');
    }

    public function update(Request $request): RedirectResponse|JsonResponse
    {
        if ($request->wantsJson()) {
            return response()->json(['status' => 'success']);
        }

        return redirect()->back();
    }

    public function post(Request $request): RedirectResponse|JsonResponse
    {
        return $this->update($request);
    }

    public function put(Request $request): RedirectResponse|JsonResponse
    {
        return $this->update($request);
    }

    public function delete(Request $request): RedirectResponse|JsonResponse
    {
        return $this->update($request);
    }
}