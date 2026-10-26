<?php

namespace Pterodactyl\Addons\Minecraft\Models;

use Illuminate\Database\Eloquent\Model;

class IconHistory extends Model
{
    protected $table = 'minecraft_tools_icon_history';

    protected $fillable = ['server_id', 'url', 'image', 'size'];
}
