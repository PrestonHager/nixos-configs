<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\Addons\PortForward\PortForwardSettingsController;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Http\Controllers\PortForwardApiController;

// Prefix /extensions/portforward, same as the Blueprint extension.
Route::get('/admin/settings', [PortForwardSettingsController::class, 'show']);
Route::put('/admin/settings', [PortForwardSettingsController::class, 'update']);
Route::post('/admin/settings/test-connection', [PortForwardApiController::class, 'testConnection']);
Route::get('/admin/audit', [PortForwardApiController::class, 'auditIndex']);

Route::group(['prefix' => '/admin/servers/{server}/mappings', 'where' => ['server' => '[0-9]+']], function () {
    Route::get('/', [PortForwardApiController::class, 'mappingsIndex']);
    Route::post('/', [PortForwardApiController::class, 'mappingsStore']);
    Route::post('/forward-primary', [PortForwardApiController::class, 'forwardPrimary']);
    Route::post('/forward-allocation/{allocationId}', [PortForwardApiController::class, 'forwardAllocation'])
        ->where('allocationId', '[0-9]+');
    Route::delete('/{mappingId}', [PortForwardApiController::class, 'mappingsDestroy']);
});
