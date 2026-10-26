<?php

namespace Pterodactyl\Addons\Sso;

use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Pterodactyl\Models\User;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Facades\Activity;
use Illuminate\Support\Facades\DB;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Event;
use Pterodactyl\Events\Auth\DirectLogin;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Users\UserCreationService;

/**
 * Zitadel single sign-on, ported from the Blueprint "sociallogin" extension
 * plus the homelab patches (Zitadel driver, root_admin sync from groups).
 *
 * Behaviour kept from the extension:
 *  - logged-in users hitting the flow link the identity to their account;
 *  - unknown identities link to an existing user by email when
 *    sociallogin::allow_connecting is on (now only for verified emails),
 *    or create a user when sociallogin::allow_register is on;
 *  - SSO logins skip the panel's TOTP checkpoint (MFA is Zitadel's job).
 */
class SsoController extends Controller
{
    public function __construct(private readonly UserCreationService $creationService)
    {
    }

    public function providers(): JsonResponse
    {
        $providers = SocialProvider::query()->where('enabled', true)->get()
            ->filter(fn (SocialProvider $p) => $p->isUsable() && $p->short_name === 'zitadel')
            ->map(fn (SocialProvider $p) => [
                'name' => $p->name,
                'short_name' => $p->short_name,
                'url' => route('sociallogin.redirect', ['provider' => $p->short_name]),
            ])
            ->values();

        return response()->json($providers);
    }

    public function connections(Request $request): JsonResponse
    {
        $connections = SocialConnection::query()->with('provider')
            ->where('user_id', $request->user()->id)
            ->get()
            ->map(fn (SocialConnection $c) => [
                'provider' => $c->provider?->short_name,
                'provider_name' => $c->provider?->name,
                'name' => $c->auth_name,
                'connected_at' => $c->created_at?->toAtomString(),
            ]);

        return response()->json(['connections' => $connections, 'providers' => $this->providers()->getData()]);
    }

    public function redirect(Request $request, string $provider): RedirectResponse
    {
        $row = $this->usableProvider($provider);
        $auth = (new ZitadelClient($row))->authorizationRequest(route('sociallogin.callback'));

        $request->session()->put('homelab_sso', [
            'provider' => $row->short_name,
            'state' => $auth['state'],
            'verifier' => $auth['verifier'],
            'nonce' => $auth['nonce'],
        ]);

        return redirect()->away($auth['url']);
    }

    public function callback(Request $request): RedirectResponse
    {
        $pending = $request->session()->pull('homelab_sso');
        if (!is_array($pending) || !isset($pending['state'], $pending['verifier'], $pending['provider'])) {
            return $this->fail('expired');
        }

        if ($request->filled('error')) {
            return $this->fail('denied');
        }

        if (!hash_equals((string) $pending['state'], (string) $request->query('state', '')) || !$request->filled('code')) {
            return $this->fail('state');
        }

        $provider = $this->usableProvider((string) $pending['provider']);

        try {
            $claims = (new ZitadelClient($provider))->user(
                (string) $request->query('code'),
                (string) $pending['verifier'],
                route('sociallogin.callback'),
            );
        } catch (\Throwable $exception) {
            report($exception);

            return $this->fail('exchange');
        }

        $subject = (string) $claims['sub'];
        $name = (string) ($claims['name'] ?? $claims['preferred_username'] ?? $subject);

        if ($user = $request->user()) {
            $this->link($user, $provider, $subject, $name);
            Activity::event('auth:social.connect')->property('provider', $provider->name)
                ->property('name', $name)->withRequestMetadata()->subject($user)->log();

            return redirect('/account/linked-accounts');
        }

        $connection = SocialConnection::query()
            ->where('provider_id', $provider->id)
            ->where('auth_id', $subject)
            ->first();

        $user = $connection?->user ?? $this->resolveNewUser($provider, $subject, $name, $claims);
        if (!$user) {
            return $this->fail('notconnected');
        }

        $this->syncAdmin($user, $claims);

        $request->session()->regenerate();
        auth()->guard()->login($user, true);
        Event::dispatch(new DirectLogin($user, true));

        Activity::event('auth:social.login')->property('provider', $provider->name)
            ->withRequestMetadata()->subject($user)->log();

        return redirect()->intended('/');
    }

    public function disconnect(Request $request, string $provider): JsonResponse
    {
        $row = SocialProvider::query()->where('short_name', $provider)->firstOrFail();

        SocialConnection::query()
            ->where('user_id', $request->user()->id)
            ->where('provider_id', $row->id)
            ->delete();

        Activity::event('auth:social.disconnect')->property('provider', $row->name)
            ->withRequestMetadata()->subject($request->user())->log();

        return response()->json([], 204);
    }

    /**
     * @param array<string, mixed> $claims
     */
    private function resolveNewUser(SocialProvider $provider, string $subject, string $name, array $claims): ?User
    {
        $email = isset($claims['email']) ? (string) $claims['email'] : null;
        $verified = filter_var($claims['email_verified'] ?? false, FILTER_VALIDATE_BOOLEAN);

        if (!$email) {
            return null;
        }

        if ($existing = User::query()->where('email', $email)->first()) {
            // Only a verified address may claim an existing account; never
            // register a second user with the same email.
            if (!$verified || !$this->setting('allow_connecting')) {
                return null;
            }

            $this->link($existing, $provider, $subject, $name);

            return $existing;
        }

        if ($this->setting('allow_register')) {
            $user = $this->creationService->handle([
                'username' => $this->uniqueUsername((string) ($claims['preferred_username'] ?? Str::before($email, '@'))),
                'email' => $email,
                'name_first' => (string) ($claims['given_name'] ?? $name),
                'name_last' => (string) ($claims['family_name'] ?? ''),
                'root_admin' => false,
            ]);
            $this->link($user, $provider, $subject, $name);

            return $user;
        }

        return null;
    }

    /**
     * Mirror Zitadel group membership onto root_admin. No groups claim at all
     * leaves the flag alone instead of demoting.
     *
     * @param array<string, mixed> $claims
     */
    private function syncAdmin(User $user, array $claims): void
    {
        $groups = ZitadelClient::groups($claims);
        if ($groups === null) {
            logger()->warning('Zitadel userinfo had no groups/roles claim; root_admin left unchanged.', ['user' => $user->id]);

            return;
        }

        $isAdmin = in_array((string) config('homelab.zitadel.admin_group'), $groups, true);
        if ((bool) $user->root_admin !== $isAdmin) {
            $user->root_admin = $isAdmin;
            $user->save();
        }
    }

    private function link(User $user, SocialProvider $provider, string $subject, string $name): void
    {
        SocialConnection::query()->updateOrCreate(
            ['user_id' => $user->id, 'provider_id' => $provider->id],
            ['auth_id' => $subject, 'auth_name' => $name],
        );
    }

    private function usableProvider(string $shortName): SocialProvider
    {
        $provider = SocialProvider::query()->where('short_name', $shortName)->first();
        abort_unless($provider && $provider->isUsable() && $provider->short_name === 'zitadel', 404);

        return $provider;
    }

    /**
     * sociallogin::* toggles, stored PHP-serialized by Blueprint's dbSet().
     */
    private function setting(string $key): bool
    {
        $raw = DB::table('settings')->where('key', "sociallogin::{$key}")->value('value');
        if ($raw === null) {
            return false;
        }

        $value = @unserialize((string) $raw, ['allowed_classes' => false]);

        return filter_var($value === false ? $raw : $value, FILTER_VALIDATE_BOOLEAN);
    }

    private function uniqueUsername(string $base): string
    {
        $base = Str::limit(preg_replace('/[^a-z0-9_.-]/', '', strtolower($base)) ?: 'user', 180, '');
        $candidate = $base;
        while (User::query()->where('username', $candidate)->exists()) {
            $candidate = $base . '-' . Str::lower(Str::random(4));
        }

        return $candidate;
    }

    private function fail(string $reason): RedirectResponse
    {
        return redirect('/auth/login?sso_error=' . urlencode($reason));
    }
}
