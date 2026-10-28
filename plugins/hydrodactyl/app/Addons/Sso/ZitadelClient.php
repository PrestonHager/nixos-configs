<?php

namespace Pterodactyl\Addons\Sso;

use Illuminate\Support\Str;
use Illuminate\Support\Facades\Http;

/**
 * Minimal OpenID Connect authorization-code client for Zitadel (PKCE + state
 * + nonce). Identity comes from the userinfo endpoint over TLS, as the
 * socialiteproviders/zitadel driver used by the Blueprint extension did.
 */
class ZitadelClient
{
    public function __construct(private readonly SocialProvider $provider)
    {
    }

    public function baseUrl(): string
    {
        return (string) config('homelab.zitadel.base_url');
    }

    /**
     * @return array{url: string, state: string, verifier: string, nonce: string}
     */
    public function authorizationRequest(string $redirectUri): array
    {
        $state = Str::random(40);
        $nonce = Str::random(40);
        $verifier = Str::random(64);

        $scopes = ['openid', 'profile', 'email'];
        if ($projectId = config('homelab.zitadel.project_id')) {
            $scopes[] = "urn:zitadel:iam:org:project:id:{$projectId}:aud";
            $scopes[] = 'urn:zitadel:iam:org:projects:roles';
        }

        $query = http_build_query([
            'client_id' => $this->provider->client_id,
            'redirect_uri' => $redirectUri,
            'response_type' => 'code',
            'scope' => implode(' ', $scopes),
            'state' => $state,
            'nonce' => $nonce,
            'code_challenge' => rtrim(strtr(base64_encode(hash('sha256', $verifier, true)), '+/', '-_'), '='),
            'code_challenge_method' => 'S256',
        ], '', '&', PHP_QUERY_RFC3986);

        return [
            'url' => $this->baseUrl() . '/oauth/v2/authorize?' . $query,
            'state' => $state,
            'verifier' => $verifier,
            'nonce' => $nonce,
        ];
    }

    /**
     * Exchange the code and fetch userinfo.
     *
     * @return array<string, mixed>
     */
    public function user(string $code, string $verifier, string $redirectUri): array
    {
        // client_secret_post, as Socialite sent it: the Zitadel app is
        // registered for that auth method.
        $token = Http::asForm()
            ->timeout(15)
            ->acceptJson()
            ->post($this->baseUrl() . '/oauth/v2/token', [
                'client_id' => (string) $this->provider->client_id,
                'client_secret' => $this->provider->secret(),
                'grant_type' => 'authorization_code',
                'code' => $code,
                'redirect_uri' => $redirectUri,
                'code_verifier' => $verifier,
            ])
            ->throw()
            ->json();

        if (!is_array($token) || empty($token['access_token'])) {
            throw new \RuntimeException('Zitadel token response did not include an access token.');
        }

        $user = Http::timeout(15)
            ->withToken($token['access_token'])
            ->get($this->baseUrl() . '/oidc/v1/userinfo')
            ->throw()
            ->json();

        if (!is_array($user) || empty($user['sub'])) {
            throw new \RuntimeException('Zitadel userinfo did not include a subject.');
        }

        return $user;
    }

    /**
     * Groups/roles from userinfo, or null when the IdP sent no such claim
     * (so a misconfigured project never demotes every admin).
     *
     * @param array<string, mixed> $user
     *
     * @return string[]|null
     */
    public static function groups(array $user): ?array
    {
        $found = false;
        $groups = [];

        if (isset($user['groups']) && is_array($user['groups'])) {
            $found = true;
            $groups = array_map('strval', $user['groups']);
        }

        foreach ($user as $claim => $value) {
            if (is_array($value) && preg_match('/^urn:zitadel:iam:org:project:(?:[0-9]+:)?roles$/', (string) $claim)) {
                $found = true;
                $groups = array_merge($groups, array_map('strval', array_keys($value)));
            }
        }

        return $found ? array_values(array_unique($groups)) : null;
    }
}
