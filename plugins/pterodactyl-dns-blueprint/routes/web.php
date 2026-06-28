<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers\DnsApiController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Http\Controllers\DnsServerAdminController;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Listeners\RegisterServerEventListeners;
use Pterodactyl\Http\Middleware\AdminAuthenticate;
use Pterodactyl\Http\Middleware\RequireTwoFactorAuthentication;

RegisterServerEventListeners::boot();

/*
| Web routes used by the admin server DNS tab (session-authenticated admin UI).
| Prefix: /extensions/dnsrecords (Blueprint "blueprint" middleware group)
*/

Route::middleware(['auth.session', RequireTwoFactorAuthentication::class, AdminAuthenticate::class])->group(function () {
    Route::get('/admin/servers/view/{server}', [DnsServerAdminController::class, 'show'])
        ->where('server', '[0-9]+')
        ->name('extensions.dnsrecords.admin.servers.view');

    Route::group(['prefix' => '/admin/servers/{server}'], function () {
        Route::get('/records', [DnsApiController::class, 'recordsIndex']);
        Route::post('/records', [DnsApiController::class, 'recordsStore']);
        Route::post('/records/delete', [DnsApiController::class, 'recordsDestroyByBody']);
        Route::patch('/records/{recordId}', [DnsApiController::class, 'recordsUpdate'])
            ->where('recordId', '.+');
        Route::delete('/records/{recordId}', [DnsApiController::class, 'recordsDestroy'])
            ->where('recordId', '.+');

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
});
