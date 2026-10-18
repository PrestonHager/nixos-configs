<?php

namespace Pterodactyl\BlueprintFramework\Extensions\MinecraftTools\Models;

use Illuminate\Database\Eloquent\Model;

class PlayerNote extends Model
{
    protected $table = 'minecraft_tools_player_notes';

    protected $guarded = ['id'];
}