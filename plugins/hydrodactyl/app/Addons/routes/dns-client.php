<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\Addons\Dns\DnsClientController;

// Prefix: /api/client/servers/{server}/dns (server access already enforced).
Route::get('/subdomain', [DnsClientController::class, 'subdomainShow']);
Route::put('/subdomain', [DnsClientController::class, 'subdomainUpdate'])->middleware('throttle:homelab-strict');
Route::get('/subdomain/check', [DnsClientController::class, 'subdomainCheck'])->middleware('throttle:homelab');
Route::get('/srv-profiles', [DnsClientController::class, 'srvProfilesIndex']);
Route::put('/srv-profiles', [DnsClientController::class, 'srvProfilesUpdate'])->middleware('throttle:homelab-strict');
Route::post('/srv-profiles/sync', [DnsClientController::class, 'srvProfilesSync'])->middleware('throttle:homelab-strict');
