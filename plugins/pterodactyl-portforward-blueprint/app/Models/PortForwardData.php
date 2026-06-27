<?php

namespace Pterodactyl\BlueprintFramework\Extensions\portforward\Models;

use Illuminate\Database\Eloquent\Model;

class PortForwardData extends Model
{
    protected $table = 'portforward_data';

    protected $fillable = ['scope', 'subject_id', 'key', 'value'];

    protected $casts = [
        'value' => 'array',
    ];
}
