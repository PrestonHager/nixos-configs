<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models;

use Illuminate\Database\Eloquent\Model;

class PluginConfig extends Model
{
    protected $table = 'minecraft_tools_plugin_configs';

    protected $guarded = ['id'];

    protected $casts = [
        'config' => 'array',
    ];
}