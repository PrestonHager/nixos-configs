<?php

namespace Pterodactyl\Addons\Sso;

use Pterodactyl\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * Row in social_connections: links a panel user to an identity (OIDC "sub").
 *
 * @property int $id
 * @property int $user_id
 * @property int $provider_id
 * @property string $auth_id
 * @property string|null $auth_name
 */
class SocialConnection extends Model
{
    protected $table = 'social_connections';

    protected $fillable = ['user_id', 'provider_id', 'auth_id', 'auth_name'];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function provider(): BelongsTo
    {
        return $this->belongsTo(SocialProvider::class, 'provider_id');
    }
}
