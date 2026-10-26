<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\Addons\Sso\SsoSettingsController;

// Prefix /extensions/homelab (admin session).
Route::get('/sso', [SsoSettingsController::class, 'show']);
Route::put('/sso', [SsoSettingsController::class, 'update']);
