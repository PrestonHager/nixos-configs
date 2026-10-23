<?php
// Pins Coolify instance settings that must not drift. Idempotent: it only
// saves what differs and prints what it changed.
//
// - Auto-update off: the image is pinned by digest in coolify.nix, and an
//   in-place self-update would run a different version than the Nix config.
//   (AUTOUPDATE=false in the container env does the same at every boot via
//   `php artisan app:init`; this also covers a toggle in the UI.)
// - Self-registration off: accounts come from Zitadel SSO (coolify-sso.nix)
//   or are created by the root user; a toggle in the UI is reverted.
// - Built-in `localhost` server (id 0, host.docker.internal) force-disabled:
//   Coolify here runs under Podman with no Docker daemon or SSH to the host,
//   so that server can never be used. force_disabled makes isFunctional() and
//   isSentinelEnabled() false, so ServerManagerJob stops dispatching
//   connection checks, Sentinel and proxy jobs for it. It is not deleted
//   because Coolify expects server 0 to exist.
// Errors are thrown; run.php turns them into a non-zero exit.
use App\Models\InstanceSettings;
use App\Models\Server;

$changes = [];

$settings = InstanceSettings::get();
if ($settings->is_auto_update_enabled) {
    $settings->is_auto_update_enabled = false;
    $settings->save();
    $changes[] = 'disabled auto-update';
}
if ($settings->is_registration_enabled) {
    $settings->is_registration_enabled = false;
    $settings->save();
    $changes[] = 'disabled self-registration';
}

$localhost = Server::with('settings')->find(0);
if (! $localhost) {
    $changes[] = 'no server 0, nothing to disable';
} elseif ($localhost->ip !== 'host.docker.internal') {
    // Someone pointed server 0 at a real host; leave it to them.
    $changes[] = "server 0 ip is {$localhost->ip}, not disabling";
} elseif (! $localhost->settings) {
    throw new RuntimeException('server 0 has no settings row');
} elseif (! $localhost->settings->force_disabled) {
    $localhost->forceDisableServer();
    $changes[] = 'force-disabled server 0 (localhost)';
}

echo $changes ? implode(PHP_EOL, $changes) . PHP_EOL : 'no changes' . PHP_EOL;
