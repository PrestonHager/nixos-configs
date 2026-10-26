<?php

namespace Pterodactyl\Addons\Minecraft\Models;

use Illuminate\Database\Eloquent\Model;

class ConfigBackup extends Model
{
    protected $table = 'minecraft_tools_config_backups';

    protected $fillable = ['server_id', 'file', 'content', 'size'];
}
