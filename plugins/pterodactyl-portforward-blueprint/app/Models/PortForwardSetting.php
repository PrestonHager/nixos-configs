<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Models;

use Illuminate\Database\Eloquent\Model;

class PortForwardSetting extends Model
{
    protected $table = 'portforward_settings';

    protected $fillable = ['key', 'value'];

    protected $casts = [
        'value' => 'array',
    ];
}
