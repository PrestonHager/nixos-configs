<?php

namespace Pterodactyl\Addons\Minecraft\Models;

use Illuminate\Database\Eloquent\Model;

class ModpackConfig extends Model
{
    protected $table = 'minecraft_tools_modpack_configs';

    protected $fillable = ['server_id', 'modpack_name', 'config'];

    protected $casts = ['config' => 'array'];
}
