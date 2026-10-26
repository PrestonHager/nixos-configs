<?php

namespace Pterodactyl\Addons;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\ServiceProvider;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Support\Facades\RateLimiter;
use Pterodactyl\Models\Server;
use Pterodactyl\Events\Server\Updated;
use Pterodactyl\Events\Server\Deleting;
use Pterodactyl\Http\Middleware\AdminAuthenticate;
use Pterodactyl\Http\Middleware\Activity\ServerSubject;
use Pterodactyl\Http\Middleware\RequireTwoFactorAuthentication;
use Pterodactyl\Http\Middleware\Api\Client\Server\ResourceBelongsToServer;
use Pterodactyl\Http\Middleware\Api\Client\Server\AuthenticateServerAccess;
use Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Listeners\RegisterServerEventListeners as DnsListeners;
use Pterodactyl\BlueprintFramework\Extensions\portforward\Listeners\RegisterServerEventListeners as PortForwardListeners;

/**
 * Homelab addons for Hydrodactyl: Zitadel SSO, DNS records, router port
 * forwarding and Minecraft tools.
 *
 * DNS and port forwarding reuse the PHP from the former Blueprint extensions
 * (copied to app/BlueprintFramework/Extensions/* at build time) so their
 * tables and stored settings carry over unchanged. URL prefixes match the
 * Blueprint ones, so the Zitadel redirect URI and API automation keep working.
 */
class AddonsServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        // The extensions declare helper classes (e.g. portforward's
        // PluginContextFactory, type-hinted by ApplyNatJob/RemoveNatJob) inside
        // PluginContext.php, where PSR-4 cannot find them. Blueprint happened
        // to load that file first; load it explicitly so the install/delete
        // hooks resolve.
        class_exists(\Pterodactyl\BlueprintFramework\Extensions\dnsrecords\Compatibility\PluginContext::class);
        class_exists(\Pterodactyl\BlueprintFramework\Extensions\portforward\Compatibility\PluginContext::class);

        // Pterodactyl's Server model mapped its model events to
        // Pterodactyl\Events\Server\*; Hydrodactyl's no longer does (only
        // Installed is still fired, by the install callback). The extensions
        // hang DNS/NAT cleanup on Deleting and SRV updates on Updated, so
        // bridge those two unless the model dispatches them itself again.
        $dispatches = (fn () => $this->dispatchesEvents)->call(new Server());
        foreach (['deleting' => Deleting::class, 'updated' => Updated::class] as $modelEvent => $event) {
            if (!isset($dispatches[$modelEvent])) {
                Server::{$modelEvent}(fn (Server $server) => event(new $event($server)));
            }
        }

        DnsListeners::boot();
        PortForwardListeners::boot();

        // Per user *and* route: plain "throttle:N,1" shares one bucket per
        // user across every route that uses it.
        $key = fn (Request $request) => ($request->user()?->id ?? $request->ip()) . '|' . $request->route()?->uri();
        RateLimiter::for('homelab', fn (Request $request) => Limit::perMinute(30)->by($key($request)));
        RateLimiter::for('homelab-strict', fn (Request $request) => Limit::perMinute(6)->by($key($request)));

        $routes = __DIR__ . '/routes';
        $admin = ['web', 'auth.session', RequireTwoFactorAuthentication::class, AdminAuthenticate::class];

        // Zitadel login/callback must stay reachable while logged out.
        Route::middleware('web')->prefix('/extensions/sociallogin')->group("$routes/sso.php");

        Route::middleware($admin)->prefix('/extensions/dnsrecords')->group("$routes/dns-admin.php");
        Route::middleware($admin)->prefix('/extensions/portforward')->group("$routes/portforward-admin.php");
        Route::middleware($admin)->prefix('/extensions/homelab')->group("$routes/homelab-admin.php");

        Route::middleware(['api', 'application-api', 'throttle:api.application'])
            ->prefix('/api/application/extensions/dnsrecords')
            ->group("$routes/dns-application.php");

        // One middleware() call: a second one replaces the list instead of appending.
        Route::middleware([
            'api',
            'client-api',
            'throttle:api.client',
            ServerSubject::class,
            AuthenticateServerAccess::class,
            ResourceBelongsToServer::class,
        ])
            ->prefix('/api/client/servers/{server}')
            ->group(function () use ($routes) {
                Route::prefix('/dns')->group("$routes/dns-client.php");
                Route::prefix('/minecraft')->group("$routes/minecraft-client.php");
            });
    }
}
