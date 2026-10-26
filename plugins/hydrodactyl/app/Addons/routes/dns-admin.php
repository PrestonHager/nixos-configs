<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\Addons\Dns\DnsSettingsController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers\DnsApiController;

// Admin JSON API behind the React DNS tab. Same paths as the Blueprint
// extension (prefix /extensions/dnsrecords), minus its Blade page.
Route::get('/admin/settings', [DnsSettingsController::class, 'show']);
Route::put('/admin/settings', [DnsSettingsController::class, 'update']);
Route::get('/admin/audit', [DnsSettingsController::class, 'audit']);

Route::group(['prefix' => '/admin/servers/{server}', 'where' => ['server' => '[0-9]+']], function () {
    Route::get('/records', [DnsApiController::class, 'recordsIndex']);
    Route::post('/records', [DnsApiController::class, 'recordsStore']);
    Route::post('/records/delete', [DnsApiController::class, 'recordsDestroyByBody']);
    Route::patch('/records/{recordId}', [DnsApiController::class, 'recordsUpdate'])->where('recordId', '.+');
    Route::delete('/records/{recordId}', [DnsApiController::class, 'recordsDestroy'])->where('recordId', '.+');

    Route::get('/srv-profiles', [DnsApiController::class, 'srvProfilesIndex']);
    Route::put('/srv-profiles', [DnsApiController::class, 'srvProfilesUpdate']);
    Route::post('/srv-profiles/sync', [DnsApiController::class, 'srvProfilesSync']);

    Route::get('/subdomain', [DnsApiController::class, 'subdomainShow']);
    Route::put('/subdomain', [DnsApiController::class, 'subdomainUpdate']);
    Route::get('/subdomain/check', [DnsApiController::class, 'subdomainCheck']);
    Route::post('/subdomain/regenerate', [DnsApiController::class, 'subdomainRegenerate']);

    Route::get('/custom-domain', [DnsApiController::class, 'customDomainShow']);
    Route::put('/custom-domain', [DnsApiController::class, 'customDomainUpdate']);
    Route::post('/custom-domain/verify', [DnsApiController::class, 'customDomainVerify']);

    Route::get('/nameserver', [DnsApiController::class, 'nameserverShow']);
    Route::put('/nameserver', [DnsApiController::class, 'nameserverUpdate']);
    Route::post('/nameserver/verify', [DnsApiController::class, 'nameserverVerify']);
});

Route::get('/admin/nameserver/pending', [DnsApiController::class, 'pendingNameserverDelegations']);
Route::post('/admin/nameserver/{server}/approve', [DnsApiController::class, 'approveNameserverDelegation'])
    ->where('server', '[0-9]+');
