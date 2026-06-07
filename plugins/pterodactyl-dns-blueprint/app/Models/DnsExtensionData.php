<?php

namespace Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * @property int $id
 * @property string $scope
 * @property int $subject_id
 * @property string $key
 * @property mixed $value
 */
class DnsExtensionData extends Model
{
    protected $table = 'dnsrecords_data';

    protected $fillable = [
        'scope',
        'subject_id',
        'key',
        'value',
    ];

    protected $casts = [
        'value' => 'array',
    ];
}
