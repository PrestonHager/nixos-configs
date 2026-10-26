<?php

namespace Pterodactyl\Addons\Sso;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Crypt;

/**
 * Row in social_providers, the table created by the former Blueprint
 * "sociallogin" extension. client_secret is stored encrypted with APP_KEY.
 *
 * @property int $id
 * @property bool $enabled
 * @property string $name
 * @property string $short_name
 * @property string|null $client_id
 * @property string|null $client_secret
 */
class SocialProvider extends Model
{
    protected $table = 'social_providers';

    public $timestamps = false;

    protected $fillable = ['enabled', 'name', 'short_name', 'client_id', 'client_secret'];

    protected $hidden = ['client_secret'];

    protected $casts = ['enabled' => 'boolean'];

    public function isUsable(): bool
    {
        return $this->enabled && !empty($this->client_id) && !empty($this->client_secret);
    }

    public function secret(): string
    {
        return Crypt::decryptString((string) $this->client_secret);
    }
}
