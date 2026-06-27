<?php

namespace Pterodactyl\Listeners;

use Illuminate\Auth\Events\Login;
use Pterodactyl\Models\User;

/**
 * Sync test panel root_admin from Zitadel groups claim after Social Login SSO.
 * Uses pterodactyl_test_admin — separate from production pterodactyl_admin.
 */
class ZitadelTestAdminSync
{
    private const ADMIN_GROUP = 'pterodactyl_test_admin';

    public function handle(Login $event): void
    {
        if (!($event->user instanceof User)) {
            return;
        }

        $groups = session()->pull('zitadel_sso_groups', []);
        if (!is_array($groups) || $groups === []) {
            return;
        }

        $isAdmin = in_array(self::ADMIN_GROUP, $groups, true);
        if ($event->user->root_admin === $isAdmin) {
            return;
        }

        $event->user->root_admin = $isAdmin;
        $event->user->save();
    }
}
