<?php

return [
    /*
    | OIDC login against the homelab Keycloak realm (replaces the Blueprint
    | "sociallogin" extension). The client id/secret live in the
    | social_providers row (short_name "keycloak"); these say where the
    | issuer is and which group makes a panel admin.
    */
    'sso' => [
        'issuer' => rtrim((string) env('SSO_ISSUER', 'https://keycloak.prestonhager.com/realms/homelab'), '/'),
        // Members of this Keycloak group become panel root admins on every
        // SSO login (and lose it when removed).
        'admin_group' => env('SSO_ADMIN_GROUP', 'pterodactyl_admin'),
    ],
];
