<?php

namespace Pterodactyl\Addons\Minecraft\Models;

use Illuminate\Database\Eloquent\Model;

class PlayerNote extends Model
{
    protected $table = 'minecraft_tools_player_notes';

    protected $fillable = ['server_id', 'username', 'uuid', 'notes', 'display_name'];
}
