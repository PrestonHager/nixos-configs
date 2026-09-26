<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models;

use Illuminate\Database\Eloquent\Model;

class IconHistory extends Model
{
    protected $table = 'minecraft_tools_icon_history';

    protected $guarded = ['id'];

    protected $casts = [
        'size' => 'integer',
    ];
}