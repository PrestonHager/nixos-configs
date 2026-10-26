<?php

return [
    /*
    | Zitadel OIDC login (replaces the Blueprint "sociallogin" extension).
    | The client id/secret live in the social_providers row; these say where
    | the issuer is and which project's roles to request.
    */
    'zitadel' => [
        'base_url' => rtrim((string) env('ZITADEL_BASE_URL', 'https://zitadel.prestonhager.com'), '/'),
        'project_id' => env('ZITADEL_PROJECT_ID'),
        // Members of this Zitadel group/role become panel root admins on
        // every SSO login (and lose it when removed).
        'admin_group' => env('ZITADEL_ADMIN_GROUP', 'pterodactyl_admin'),
    ],
];
