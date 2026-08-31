# Pterodactyl Blueprint: Adding an Extension (Legacy ABI Recipe)

**Status:** Worked example = `minecraft-tools` (implemented 2026-08, legacy ABI port)
**Branch:** `dell-poweredge-r730xd`
**Panel:** https://panel.prestonhager.com  (prod) / https://test.panel.prestonhager.com (test)
**Related:** [pterodactyl-plugin-port-forward.md](./pterodactyl-plugin-port-forward.md), [pterodactyl-ace.md](./pterodactyl-ace.md)

---

## Why a "legacy ABI" port

The upstream `minecraft-tools` extension targets the **2.0 extension API**
(`App\Extensions\*`, requires `blueprint/extensions`, `Blueprint\Extensions\ExtensionManager`).
The framework release installed on this panel (v1.x) does **not** provide that API, so the
upstream controllers are all stubs. The extension was therefore rebuilt on the **legacy ABI**
the same way `portforward` and `dnsrecords` already work:

- panel composer autoload `Pterodactyl\\ -> app/`
- `routes/blueprint/web/*.php` files auto-mounted at `/<name>`
- admin extension controller at `app/Http/Controllers/Admin/Extensions/<Name>/`
- views under `resources/views/admin/extensions/<name>/` extending `layouts.admin`

## What was built for minecraft-tools

| Component | Path in repo (deployed from `/pterodactyl/html`) |
|-----------|------|
| Backend classes | `nixos/containers/mc-tools-port/app/BlueprintFramework/Extensions/MinecraftTools/` |
| API controller | `.../MinecraftToolsApiController.php` |
| Admin controller | `.../Http/Controllers/Admin/Extensions/MinecraftTools/MinecraftToolsExtensionController.php` |
| Routes | `.../routes/blueprint/web/minecraft-tools.php` |
| Config | `.../config/minecraft-tools.php` |
| Models | `.../BlueprintFramework/Extensions/MinecraftTools/Models/*.php` |
| Migration | `database/migrations/2024_01_01_000000_create_minecraft_tools_tables.php` |
| Views | generated from upstream `Resources/views/admin/*.blade.php` at install time (see wiring) |
| Nix wiring | `nixos/containers/pterodactyl-blueprint.nix` -> `ensure_minecraft_tools_legacy_wiring` |

### Route surface (verified `php artisan route:list`, exit 0)

- Admin extension index: `/admin/extensions/minecraft-tools` (hyphen-safe via `$classSafe`)
- Tab views: `/minecraft-tools/{plugins,versions,players,modpacks,config,icon}`
- API (session auth, CSRF-exempt): `/minecraft-tools/api/...`

### Data model (5 tables, all `unsignedInteger('server_id')` FK to `servers.id`)

`minecraft_tools_plugin_configs`, `minecraft_tools_modpack_configs`,
`minecraft_tools_icon_history`, `minecraft_tools_config_backups`,
`minecraft_tools_player_notes`.

## Recipe: adding a NEW extension (repeatable)

1. **Source layout.** Keep the legacy ABI surface in a standalone directory in the repo,
   e.g. `nixos/containers/<ext>-port/`. PHP code is deployed verbatim; no framework symlink
   is required since everything resolves under `app/`.
2. **Identifier + controller naming.** Blueprint mounts admin controllers at
   `...\Admin\Extensions\{identifier}\{identifier}ExtensionController`. Classic hyphenated
   identifiers (like `minecraft-tools`) break route resolution, so the router patch in
   `ensure_minecraft_tools_legacy_wiring` rewrites `routes/blueprint.php` to use a
   `$classSafe = preg_replace("/-/", "", $identifier)` and resolves
   `...\Extensions\{$classSafe}\{$classSafe}ExtensionController`. This is applied
   idempotently on every switch (delete-then-append; see the wiring function).
3. **Routes file.** `routes/blueprint/web/<identifer>.php` is auto-mounted at `/<identifier>`
   with no extra registration. Put tab views + auth middleware group + an `api` prefix group
   (wrap with `->withoutMiddleware(VerifyCsrfToken::class)`; auth is session-based web
   middleware, so CSRF enforcement would 419 form POSTs).
4. **Views.** Upstream blades in this repo use `@extends('admin.layouts.default')`, which the
   panel does not ship. The wiring derives panel-safe views with:
   `sed -e "s/@extends('admin.layouts.default')/@extends('layouts.admin')/"`
   and rewrites any `/api/extensions/<id>` fetch URLs to `/<id>/api`.
   The extension's index view `<name>/index.blade.php` is exempted from the framework's
   `ensure_extension_admin_files` resync (`[ "$ext" != "minecraft-tools" ] &&`) so the
   derived copy is never overwritten.
5. **Migration.** Ship a standard migration (single, dated) under `migrations/`; the install
   script copies it and applies when the framework integration runs. Verify with
   `php artisan migrate:status`.
6. **Nix wiring.** Add `let` bindings for the port dir and the source tree, then a
   `ensure_<ext>_legacy_wiring()` function that: removes the broken generated controller dir,
   copies the controller/classes/routes/config (chown `pterodactyl:pterodactyl`,
   cmp-guarded), derives views with sed, applies the blueprint.php patch, runs
   `composer dump-autoload -o`, clears route/config/view caches, and greps
   `route:list` for the routes. Call it from **both** `post_install_hooks()` **and** the
   fast-path (after `refresh_blueprint_framework_release`, before the pre/post version
   comparison) so it runs even when a framework release refresh restores `blueprint.php`.
7. **Rebuild + verify.**
   - `nix eval .#nixosConfigurations.ace.config.system.build.toplevel.drvPath` (eval gate)
   - `nixos-rebuild switch --flake .`; check `systemctl status pterodactyl-blueprint-install.service` = SUCCESS
   - `podman exec pterodactyl php /var/www/pterodactyl/artisan route:list` -> expect `rc=0` and the new routes
   - Panel reachability is via caddy -> `php_fastcgi localhost:9001` (prod) / `9002` (test).
     Direct `curl :9001` returns a reset by design (fastcgi, not HTTP). Use host-header over
     HTTPS: `curl -sk --resolve panel.prestonhager.com:443:127.0.0.1 https://panel.prestonhager.com/...`
   - Restart the service once more to exercise the idempotent fast path.

## Gotchas learned

- **Nix `''...''` strings:** watch for `''` and `${`; PHP heredocs inside `writeShellScript`
  must avoid both (`preg_replace("/-/", ...)` style double-quotes instead of single-quote
  regex delimiters avoids `''`).
- **sed BRE braces:** escape nothing around literal `{`/`}` in GNU sed patterns; escaping as
  `\{` triggers "Invalid content of \{\}".
- **php -l is not runtime:** a bad regex pattern delimiter (e.g. `preg_replace("/-", "")`)
  parses fine but throws at request time. Lint AND execute the pattern.
- **`routes/blueprint/web.php` auto-mounts every file in that dir** with prefix =
  filename minus `.php`; do not duplicate registration elsewhere.
- **Blueprint.php patch must self-heal.** The `classSafe` guard was switched from grep-based
  to unconditional delete-then-append so a malformed prior insert is repaired on re-run.
- **Flake path literals resolve from the module file's directory.** Use `./mc-tools-port`
  for a sibling directory of the module; `../mc-tools-port` resolves one level higher and
  fails eval with "Path '...' does not exist in Git repository".
- Keep ssh key loading working (`Start-Service ssh-agent; ssh-add <key>` on the client) or
  remote verification stalls.