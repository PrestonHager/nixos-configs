<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\Addons\Sso\SsoController;

// Paths match the former Blueprint "sociallogin" extension so the redirect URI
// registered in Zitadel (/extensions/sociallogin/callback) stays valid.
Route::get('/providers', [SsoController::class, 'providers'])->name('sociallogin.providers');
Route::get('/redirect/{provider}', [SsoController::class, 'redirect'])
    ->middleware('throttle:authentication')
    ->name('sociallogin.redirect');
Route::get('/callback', [SsoController::class, 'callback'])
    ->middleware('throttle:authentication')
    ->name('sociallogin.callback');

Route::middleware('auth.session')->group(function () {
    Route::get('/connections', [SsoController::class, 'connections'])->name('sociallogin.connections');
    Route::get('/connect/{provider}', [SsoController::class, 'redirect'])->name('sociallogin.connect');
    Route::delete('/connections/{provider}', [SsoController::class, 'disconnect'])->name('sociallogin.disconnect');
});
