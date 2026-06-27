<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Http\Controllers\PortForwardApiController;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Http\Controllers\PortForwardServerAdminController;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Listeners\RegisterServerEventListeners;
use Pterodactyl\Http\Middleware\AdminAuthenticate;
use Pterodactyl\Http\Middleware\RequireTwoFactorAuthentication;

RegisterServerEventListeners::boot();

Route::middleware(['auth.session', RequireTwoFactorAuthentication::class, AdminAuthenticate::class])->group(function () {
    Route::get('/admin/servers/view/{server}', [PortForwardServerAdminController::class, 'show'])
        ->where('server', '[0-9]+')
        ->name('extensions.portforward.admin.servers.view');

    Route::get('/admin/servers/{server}/mappings', [PortForwardApiController::class, 'mappingsIndex']);
    Route::post('/admin/servers/{server}/mappings', [PortForwardApiController::class, 'mappingsStore']);
    Route::delete('/admin/servers/{server}/mappings/{mappingId}', [PortForwardApiController::class, 'mappingsDestroy']);
    Route::post('/admin/servers/{server}/mappings/forward-primary', [PortForwardApiController::class, 'forwardPrimary']);
    Route::get('/admin/audit', [PortForwardApiController::class, 'auditIndex']);
    Route::post('/admin/settings/test-connection', [PortForwardApiController::class, 'testConnection']);
});
