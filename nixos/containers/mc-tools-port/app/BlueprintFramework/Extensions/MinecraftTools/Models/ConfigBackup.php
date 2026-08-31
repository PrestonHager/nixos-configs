<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models;

use Illuminate\Database\Eloquent\Model;

class ConfigBackup extends Model
{
    protected $table = 'minecraft_tools_config_backups';

    protected $guarded = ['id'];

    protected $casts = [
        'size' => 'integer',
    ];
}