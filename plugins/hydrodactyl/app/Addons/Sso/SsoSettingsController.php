<?php

namespace Pterodactyl\Addons\Sso;

use Illuminate\Http\Request;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Crypt;
use Pterodactyl\Http\Controllers\Controller;

class SsoSettingsController extends Controller
{
    public function show(): JsonResponse
    {
        $provider = SocialProvider::query()->where('short_name', 'zitadel')->first();

        return response()->json([
            'provider' => [
                'enabled' => (bool) $provider?->enabled,
                'name' => $provider?->name ?? 'Zitadel',
                'client_id' => $provider?->client_id ?? '',
                'client_secret_set' => !empty($provider?->client_secret),
            ],
            'allow_register' => $this->get('allow_register'),
            'allow_connecting' => $this->get('allow_connecting'),
            'issuer' => config('homelab.zitadel.base_url'),
            'project_id' => config('homelab.zitadel.project_id'),
            'admin_group' => config('homelab.zitadel.admin_group'),
            'callback_url' => route('sociallogin.callback'),
        ]);
    }

    public function update(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'enabled' => 'required|boolean',
            'name' => 'required|string|max:191',
            'client_id' => 'nullable|string',
            'client_secret' => 'nullable|string',
            'allow_register' => 'required|boolean',
            'allow_connecting' => 'required|boolean',
        ]);

        $provider = SocialProvider::query()->firstOrNew(['short_name' => 'zitadel']);
        $provider->enabled = $validated['enabled'];
        $provider->name = $validated['name'];
        $provider->client_id = $validated['client_id'] ?: $provider->client_id;
        if (!empty($validated['client_secret'])) {
            $provider->client_secret = Crypt::encryptString($validated['client_secret']);
        }
        $provider->save();

        $this->set('allow_register', $validated['allow_register']);
        $this->set('allow_connecting', $validated['allow_connecting']);

        return $this->show();
    }

    private function get(string $key): bool
    {
        $raw = DB::table('settings')->where('key', "sociallogin::{$key}")->value('value');
        $value = $raw === null ? false : @unserialize((string) $raw, ['allowed_classes' => false]);

        return filter_var($value, FILTER_VALIDATE_BOOLEAN);
    }

    // Same encoding as Blueprint's dbSet() so the values stay readable by both.
    private function set(string $key, bool $value): void
    {
        DB::table('settings')->updateOrInsert(['key' => "sociallogin::{$key}"], ['value' => serialize($value ? '1' : '0')]);
    }
}
