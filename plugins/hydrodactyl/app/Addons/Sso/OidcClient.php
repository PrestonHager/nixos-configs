<?php

namespace Pterodactyl\Addons\Sso;

use Illuminate\Support\Str;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Cache;

/**
 * Minimal OpenID Connect authorization-code client (PKCE + state + nonce)
 * for the homelab Keycloak realm. Endpoints come from the issuer's discovery
 * document; identity comes from the userinfo endpoint over TLS.
 */
class OidcClient
{
    /** social_providers.short_name of the one provider the panel offers. */
    public const PROVIDER = 'keycloak';

    public function __construct(private readonly SocialProvider $provider)
    {
    }

    public static function issuer(): string
    {
        return (string) config('homelab.sso.issuer');
    }

    /**
     * @return array<string, mixed>
     */
    private function discovery(): array
    {
        $issuer = self::issuer();

        return Cache::remember('homelab_sso_discovery:' . sha1($issuer), now()->addHour(), function () use ($issuer) {
            $doc = Http::timeout(15)->acceptJson()
                ->get($issuer . '/.well-known/openid-configuration')
                ->throw()
                ->json();
            if (!is_array($doc) || ($doc['issuer'] ?? null) !== $issuer) {
                throw new \RuntimeException('OIDC discovery document does not match the configured issuer.');
            }

            return $doc;
        });
    }

    private function endpoint(string $name): string
    {
        $url = (string) ($this->discovery()[$name] ?? '');
        if ($url === '') {
            throw new \RuntimeException("OIDC discovery document has no {$name}.");
        }

        return $url;
    }

    /**
     * @return array{url: string, state: string, verifier: string, nonce: string}
     */
    public function authorizationRequest(string $redirectUri): array
    {
        $state = Str::random(40);
        $nonce = Str::random(40);
        $verifier = Str::random(64);

        // The client's default scopes add the flat `groups` claim.
        $query = http_build_query([
            'client_id' => $this->provider->client_id,
            'redirect_uri' => $redirectUri,
            'response_type' => 'code',
            'scope' => 'openid profile email',
            'state' => $state,
            'nonce' => $nonce,
            'code_challenge' => rtrim(strtr(base64_encode(hash('sha256', $verifier, true)), '+/', '-_'), '='),
            'code_challenge_method' => 'S256',
        ], '', '&', PHP_QUERY_RFC3986);

        return [
            'url' => $this->endpoint('authorization_endpoint') . '?' . $query,
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
        $token = Http::asForm()
            ->timeout(15)
            ->acceptJson()
            ->post($this->endpoint('token_endpoint'), [
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
            throw new \RuntimeException('OIDC token response did not include an access token.');
        }

        $user = Http::timeout(15)
            ->withToken($token['access_token'])
            ->get($this->endpoint('userinfo_endpoint'))
            ->throw()
            ->json();

        if (!is_array($user) || empty($user['sub'])) {
            throw new \RuntimeException('OIDC userinfo did not include a subject.');
        }

        return $user;
    }

    /**
     * The flat `groups` claim (Keycloak group names), or null when the IdP
     * sent no such claim (so a misconfigured client never demotes every admin).
     *
     * @param array<string, mixed> $user
     *
     * @return string[]|null
     */
    public static function groups(array $user): ?array
    {
        if (!isset($user['groups']) || !is_array($user['groups'])) {
            return null;
        }

        // Plain names; a "/group" path (full.path mapper) is reduced to its name.
        return array_values(array_unique(array_map(
            fn ($g) => ltrim((string) $g, '/'),
            $user['groups'],
        )));
    }
}
