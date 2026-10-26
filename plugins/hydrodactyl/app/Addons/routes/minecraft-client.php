<?php

use Illuminate\Support\Facades\Route;
use Pterodactyl\Addons\Minecraft\ModpackController;
use Pterodactyl\Addons\Minecraft\MinecraftController;

// Prefix: /api/client/servers/{server}/minecraft (server access enforced;
// each action also checks its own subuser permission).
Route::get('/', [MinecraftController::class, 'overview']);

Route::get('/versions', [MinecraftController::class, 'versions'])->middleware('throttle:homelab');
Route::get('/versions/builds', [MinecraftController::class, 'builds'])->middleware('throttle:homelab');
Route::put('/versions', [MinecraftController::class, 'switchVersion'])->middleware('throttle:homelab-strict');

Route::get('/addons', [MinecraftController::class, 'addons']);
Route::post('/addons/toggle', [MinecraftController::class, 'toggleAddon']);
Route::delete('/addons', [MinecraftController::class, 'deleteAddon']);

Route::get('/players', [MinecraftController::class, 'players']);
Route::post('/players/action', [MinecraftController::class, 'playerAction'])->middleware('throttle:homelab');
Route::put('/players/notes', [MinecraftController::class, 'playerNotes']);

Route::get('/properties', [MinecraftController::class, 'properties']);
Route::put('/properties', [MinecraftController::class, 'updateProperties']);
Route::get('/properties/backups', [MinecraftController::class, 'propertyBackups']);
Route::post('/properties/backups/{backup}/restore', [MinecraftController::class, 'restorePropertyBackup'])
    ->where('backup', '[0-9]+');

Route::get('/icon', [MinecraftController::class, 'icon']);
Route::post('/icon', [MinecraftController::class, 'uploadIcon'])->middleware('throttle:homelab-strict');
Route::post('/icon/generate', [MinecraftController::class, 'generateIcon'])->middleware('throttle:homelab');
Route::post('/icon/history/{history}/restore', [MinecraftController::class, 'restoreIcon'])->where('history', '[0-9]+');
Route::delete('/icon', [MinecraftController::class, 'deleteIcon']);

Route::get('/modpacks/search', [ModpackController::class, 'search'])->middleware('throttle:homelab');
Route::get('/modpacks/installed', [ModpackController::class, 'installed']);
Route::get('/modpacks/{project}/versions', [ModpackController::class, 'versions'])->middleware('throttle:homelab');
Route::post('/modpacks', [ModpackController::class, 'install'])->middleware('throttle:homelab-strict');
Route::delete('/modpacks/{modpack}', [ModpackController::class, 'destroy'])->where('modpack', '[0-9]+');
