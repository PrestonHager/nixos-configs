<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers\DnsApiController;

/*
| Application API routes for admin DNS management.
| Prefix: /api/application/extensions/dnsrecords
| Requires application API key (admin panel session uses admin routes below).
*/

Route::group(['prefix' => '/servers/{server}'], function () {
    Route::get('/records', [DnsApiController::class, 'recordsIndex']);
    Route::post('/records', [DnsApiController::class, 'recordsStore']);
    Route::patch('/records/{recordId}', [DnsApiController::class, 'recordsUpdate']);
    Route::delete('/records/{recordId}', [DnsApiController::class, 'recordsDestroy']);

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
Route::post('/admin/nameserver/{server}/approve', [DnsApiController::class, 'approveNameserverDelegation']);
