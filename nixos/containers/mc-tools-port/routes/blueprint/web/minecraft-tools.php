<?php

use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Support\Facades\Route;
use Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\MinecraftToolsApiController;
use Pterodactyl\Http\Controllers\Admin\Extensions\minecrafttools\minecrafttoolsExtensionController;
use Pterodactyl\Http\Middleware\AdminAuthenticate;
use Pterodactyl\Http\Middleware\RequireTwoFactorAuthentication;

Route::middleware(['auth.session', RequireTwoFactorAuthentication::class, AdminAuthenticate::class])->group(function () {
    Route::get('plugins', [minecrafttoolsExtensionController::class, 'plugins'])->name('admin.extensions.minecraft-tools.plugins');
    Route::get('versions', [minecrafttoolsExtensionController::class, 'versions'])->name('admin.extensions.minecraft-tools.versions');
    Route::get('players', [minecrafttoolsExtensionController::class, 'players'])->name('admin.extensions.minecraft-tools.players');
    Route::get('modpacks', [minecrafttoolsExtensionController::class, 'modpacks'])->name('admin.extensions.minecraft-tools.modpacks');
    Route::get('config', [minecrafttoolsExtensionController::class, 'config'])->name('admin.extensions.minecraft-tools.config');
    Route::get('icon', [minecrafttoolsExtensionController::class, 'icon'])->name('admin.extensions.minecraft-tools.icon');

    Route::prefix('api')->withoutMiddleware(VerifyCsrfToken::class)->group(function () {
        /* plugins */
        Route::get('plugins', [MinecraftToolsApiController::class, 'pluginsIndex']);
        Route::post('plugins', [MinecraftToolsApiController::class, 'pluginStore']);
        Route::get('plugins/available', [MinecraftToolsApiController::class, 'pluginAvailable']);
        Route::post('plugins/search', [MinecraftToolsApiController::class, 'pluginSearch']);
        Route::get('plugins/{plugin}', [MinecraftToolsApiController::class, 'pluginShow']);
        Route::put('plugins/{plugin}', [MinecraftToolsApiController::class, 'pluginUpdate']);
        Route::delete('plugins/{plugin}', [MinecraftToolsApiController::class, 'pluginDestroy']);
        Route::post('plugins/{plugin}/install', [MinecraftToolsApiController::class, 'pluginInstall']);
        Route::post('plugins/{plugin}/uninstall', [MinecraftToolsApiController::class, 'pluginUninstall']);
        Route::post('plugins/{plugin}/enable', [MinecraftToolsApiController::class, 'pluginToggle'])->defaults('state', 'enable');
        Route::post('plugins/{plugin}/disable', [MinecraftToolsApiController::class, 'pluginToggle'])->defaults('state', 'disable');
        Route::get('plugins/{plugin}/config', [MinecraftToolsApiController::class, 'pluginGetConfig']);
        Route::put('plugins/{plugin}/config', [MinecraftToolsApiController::class, 'pluginUpdateConfig']);

        /* versions */
        Route::get('versions', [MinecraftToolsApiController::class, 'versionsIndex']);
        Route::post('versions', [MinecraftToolsApiController::class, 'versionInstall']);
        Route::get('versions/available', [MinecraftToolsApiController::class, 'versionsAvailable']);
        Route::get('versions/current', [MinecraftToolsApiController::class, 'versionCurrent']);
        Route::post('versions/switch', [MinecraftToolsApiController::class, 'versionSwitch']);
        Route::get('versions/builds/{version}', [MinecraftToolsApiController::class, 'versionBuilds']);
        Route::delete('versions/{version}', [MinecraftToolsApiController::class, 'versionDestroy']);

        /* players */
        Route::get('players', [MinecraftToolsApiController::class, 'playersIndex']);
        Route::post('players', [MinecraftToolsApiController::class, 'playerStore']);
        Route::post('players/{player}/ban', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'ban');
        Route::post('players/{player}/unban', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'unban');
        Route::post('players/{player}/kick', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'kick');
        Route::post('players/{player}/whitelist', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'whitelist');
        Route::post('players/{player}/unwhitelist', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'unwhitelist');
        Route::post('players/{player}/op', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'op');
        Route::post('players/{player}/deop', [MinecraftToolsApiController::class, 'playerAction'])->defaults('action', 'deop');
        Route::get('players/{player}/logs', [MinecraftToolsApiController::class, 'playerLogs']);
        Route::put('players/{player}', [MinecraftToolsApiController::class, 'playerUpdate']);
        Route::delete('players/{player}', [MinecraftToolsApiController::class, 'playerDestroy']);

        /* modpacks */
        Route::get('modpacks', [MinecraftToolsApiController::class, 'modpacksIndex']);
        Route::post('modpacks', [MinecraftToolsApiController::class, 'modpackStore']);
        Route::get('modpacks/categories', [MinecraftToolsApiController::class, 'modpackCategories']);
        Route::post('modpacks/search', [MinecraftToolsApiController::class, 'modpackSearch']);
        Route::get('modpacks/{modpack}', [MinecraftToolsApiController::class, 'modpackShow']);
        Route::delete('modpacks/{modpack}', [MinecraftToolsApiController::class, 'modpackDestroy']);
        Route::get('modpacks/{modpack}/versions', [MinecraftToolsApiController::class, 'modpackVersions']);
        Route::post('modpacks/{modpack}/switch-version', [MinecraftToolsApiController::class, 'modpackSwitchVersion']);
        Route::get('modpacks/{modpack}/config', [MinecraftToolsApiController::class, 'modpackGetConfig']);
        Route::put('modpacks/{modpack}/config', [MinecraftToolsApiController::class, 'modpackUpdateConfig']);

        /* config editor */
        Route::get('config', [MinecraftToolsApiController::class, 'configIndex']);
        Route::get('config/files', [MinecraftToolsApiController::class, 'configListFiles']);
        Route::post('config/validate', [MinecraftToolsApiController::class, 'configValidate']);
        Route::get('config/templates', [MinecraftToolsApiController::class, 'configTemplates']);
        Route::get('config/{file}', [MinecraftToolsApiController::class, 'configShow']);
        Route::get('config/{file}/raw', [MinecraftToolsApiController::class, 'configGetRaw']);
        Route::put('config/{file}/raw', [MinecraftToolsApiController::class, 'configUpdateRaw']);
        Route::get('config/{file}/backup', [MinecraftToolsApiController::class, 'configBackup']);
        Route::post('config/{file}/restore', [MinecraftToolsApiController::class, 'configRestore']);

        /* icon */
        Route::get('icon', [MinecraftToolsApiController::class, 'iconIndex']);
        Route::delete('icon', [MinecraftToolsApiController::class, 'iconDelete']);
        Route::post('icon/upload', [MinecraftToolsApiController::class, 'iconUpload']);
        Route::post('icon/generate', [MinecraftToolsApiController::class, 'iconGenerate']);
        Route::get('icon/templates', [MinecraftToolsApiController::class, 'iconTemplates']);
        Route::get('icon/history', [MinecraftToolsApiController::class, 'iconHistory']);
    });
});