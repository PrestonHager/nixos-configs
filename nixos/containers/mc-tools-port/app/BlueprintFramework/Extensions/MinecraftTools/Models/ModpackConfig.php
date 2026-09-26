<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models;

use Illuminate\Database\Eloquent\Model;

class ModpackConfig extends Model
{
    protected $table = 'minecraft_tools_modpack_configs';

    protected $guarded = ['id'];

    protected $casts = [
        'config' => 'array',
    ];
}