<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * @property int $id
 * @property string $key
 * @property mixed $value
 */
class DnsExtensionSetting extends Model
{
    protected $table = 'dnsrecords_settings';

    protected $fillable = [
        'key',
        'value',
    ];

    protected $casts = [
        'value' => 'array',
    ];
}
