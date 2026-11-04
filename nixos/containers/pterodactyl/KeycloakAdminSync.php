<?php

namespace Pterodactyl\Listeners;

use Illuminate\Auth\Events\Login;
use Pterodactyl\Models\User;

/**
 * Sync panel root_admin from the Keycloak groups claim after Social Login SSO.
 * The patched SocialAuthController stores the flat `groups` claim in the
 * session as sso_groups (pterodactyl-sso.nix, pterodactyl-test-sso.nix).
 */
class KeycloakAdminSync
{
    private const ADMIN_GROUP = 'pterodactyl_admin';

    public function handle(Login $event): void
    {
        if (!($event->user instanceof User)) {
            return;
        }

        $groups = session()->pull('sso_groups', []);
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
