<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers\DnsApiController;

/*
| Client API routes (optional — admin-only deployment can ignore these).
| Prefix: /api/client/extensions/dnsrecords
*/

Route::group(['prefix' => '/servers/{server}'], function () {
    Route::get('/subdomain', [DnsApiController::class, 'subdomainShow']);
    Route::put('/subdomain', [DnsApiController::class, 'subdomainUpdate']);
    Route::get('/subdomain/check', [DnsApiController::class, 'subdomainCheck']);
    Route::get('/srv-profiles', [DnsApiController::class, 'srvProfilesIndex']);
    Route::put('/srv-profiles', [DnsApiController::class, 'srvProfilesUpdate']);
    Route::post('/srv-profiles/sync', [DnsApiController::class, 'srvProfilesSync']);
});
