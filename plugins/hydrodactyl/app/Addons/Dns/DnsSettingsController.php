<?php

namespace Pterodactyl\Addons\Dns;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Services;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\PrimaryDomain;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\CloudflareZoneId;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Com\Prestonhager\Dns\Support\ExtensionDefaults;

/**
 * JSON replacement for the Blueprint DNS settings page (admin/controller.php).
 * Same keys, defaults and sanitizing; API tokens are write-only.
 */
class DnsSettingsController extends Controller
{
    private const SECRETS = ['cloudflare_api_token', 'technitium_api_token'];

    public function show(): JsonResponse
    {
        $settings = array_merge($this->defaults(), PluginContext::make()->config()->all());

        if (empty($settings['srv_profiles'])) {
            $settings['srv_profiles'] = ExtensionDefaults::srvProfiles();
        }
        if (!is_array($settings['primary_domains'] ?? null)) {
            $settings['primary_domains'] = ExtensionDefaults::primaryDomains();
        }

        foreach (self::SECRETS as $key) {
            $settings[$key . '_set'] = !empty($settings[$key]);
            unset($settings[$key]);
        }

        // Prod hands the tokens over as files from sops (see the Nix module);
        // those take precedence over anything stored here.
        $settings['cloudflare_token_from_env'] = (getenv('CLOUDFLARE_API_TOKEN_FILE') ?: getenv('CLOUDFLARE_API_TOKEN') ?: '') !== '';
        $settings['technitium_token_from_env'] = (getenv('TECHNITIUM_API_TOKEN_FILE') ?: getenv('TECHNITIUM_API_TOKEN') ?: '') !== '';

        return response()->json(['settings' => $settings]);
    }

    public function update(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'cloudflare_api_token' => 'nullable|string',
            'technitium_api_token' => 'nullable|string',
            'dns_provider_mode' => 'required|string|in:cloudflare,technitium,both',
            'technitium_api_url' => 'nullable|string',
            'technitium_default_zone' => 'nullable|string',
            'dry_run' => 'boolean',
            'update_on_allocation_change' => 'boolean',
            'zone_id' => 'required|string',
            'base_domain' => 'required|string',
            'auto_provision_enabled' => 'boolean',
            'default_ttl' => 'nullable|integer|min:1',
            'subdomain_generation' => 'nullable|string',
            'client_subdomain_policy' => 'nullable|string',
            'client_change_limit' => 'nullable|integer|min:0',
            'client_change_period_hours' => 'nullable|integer|min:1',
            'min_label_length' => 'nullable|integer|min:1',
            'max_label_length' => 'nullable|integer|min:3',
            'allow_custom_domain' => 'boolean',
            'custom_domain_mode' => 'nullable|string',
            'srv_profiles' => 'nullable|array',
            'primary_domains' => 'nullable|array',
            'reserved_labels' => 'nullable|array',
        ]);

        $context = PluginContext::make();
        $settings = array_merge($this->defaults(), $context->config()->all(), [
            'zone_id' => CloudflareZoneId::isZoneId($validated['zone_id']) ? strtolower($validated['zone_id']) : $validated['zone_id'],
            'base_domain' => $validated['base_domain'],
            'auto_provision_enabled' => $request->boolean('auto_provision_enabled'),
            'default_ttl' => (int) ($validated['default_ttl'] ?? 1),
            'subdomain_generation' => $validated['subdomain_generation'] ?? 'server_slug',
            'client_subdomain_policy' => $validated['client_subdomain_policy'] ?? 'never',
            'client_change_limit' => (int) ($validated['client_change_limit'] ?? 1),
            'client_change_period_hours' => (int) ($validated['client_change_period_hours'] ?? 168),
            'min_label_length' => (int) ($validated['min_label_length'] ?? 3),
            'max_label_length' => (int) ($validated['max_label_length'] ?? 32),
            'allow_custom_domain' => $request->boolean('allow_custom_domain'),
            'custom_domain_mode' => $validated['custom_domain_mode'] ?? 'cname',
            'dns_provider_mode' => $validated['dns_provider_mode'],
            'technitium_api_url' => $validated['technitium_api_url'] ?? 'http://host.containers.internal:5380',
            'technitium_default_zone' => $validated['technitium_default_zone'] ?? 'prestonhager.com',
            'dry_run' => $request->boolean('dry_run'),
            'update_on_allocation_change' => $request->boolean('update_on_allocation_change'),
        ]);

        // Blank secret fields mean "keep the stored value".
        foreach (self::SECRETS as $key) {
            if (!empty($validated[$key])) {
                $settings[$key] = $validated[$key];
            }
        }

        if (isset($validated['srv_profiles'])) {
            $settings['srv_profiles'] = array_values($validated['srv_profiles']);
        }
        if (isset($validated['reserved_labels'])) {
            $settings['reserved_labels'] = array_values(array_filter(array_map('strval', $validated['reserved_labels'])));
        }
        if (isset($validated['primary_domains'])) {
            $settings['primary_domains'] = $this->sanitizePrimaryDomains(
                $validated['primary_domains'],
                $settings['zone_id'],
                $settings['base_domain'],
            );
        }

        $context->config()->replace($settings);

        return $this->show();
    }

    public function audit(Request $request): JsonResponse
    {
        $serverId = $request->query('server');

        return response()->json([
            'entries' => Services::auditLog(PluginContext::make())->recent(
                min(200, max(1, (int) $request->query('limit', 50))),
                is_numeric($serverId) ? (int) $serverId : null,
            ),
        ]);
    }

    /**
     * @param array<int, mixed> $entries
     *
     * @return array<int, array<string, mixed>>
     */
    private function sanitizePrimaryDomains(array $entries, string $defaultZoneId, string $baseDomain): array
    {
        $sanitized = [];

        foreach ($entries as $entry) {
            if (!is_array($entry) || is_null($domain = PrimaryDomain::fromConfigEntry($entry, $defaultZoneId, $baseDomain))) {
                continue;
            }

            if ($domain->zoneId === $defaultZoneId) {
                unset($entry['zone_id']);
            } else {
                $entry['zone_id'] = $domain->zoneId;
            }

            $sanitized[] = $entry;
        }

        return $sanitized;
    }

    /**
     * @return array<string, mixed>
     */
    private function defaults(): array
    {
        return [
            'cloudflare_api_token' => '',
            'zone_id' => '',
            'base_domain' => '',
            'auto_provision_enabled' => true,
            'default_ttl' => 1,
            'srv_profiles' => ExtensionDefaults::srvProfiles(),
            'primary_domains' => ExtensionDefaults::primaryDomains(),
            'subdomain_generation' => 'server_slug',
            'client_subdomain_policy' => 'never',
            'client_change_limit' => 1,
            'client_change_period_hours' => 168,
            'reserved_labels' => [],
            'min_label_length' => 3,
            'max_label_length' => 32,
            'allow_custom_domain' => false,
            'custom_domain_mode' => 'cname',
            'dns_provider_mode' => 'cloudflare',
            'technitium_api_url' => 'http://host.containers.internal:5380',
            'technitium_api_token' => '',
            'technitium_default_zone' => 'prestonhager.com',
            'dry_run' => false,
            'update_on_allocation_change' => true,
        ];
    }
}
