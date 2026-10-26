# Pterodactyl → Hydrodactyl Migration

**Status:** **Production migrated 2026-10-26 01:08 UTC**; both panels run Hydrodactyl v6.4.2. Rollback material in `/var/backups/hydrodactyl-cutover-20261026T010714Z`
**Updated:** 2026-10-25
**Branch:** `dell-poweredge-r730xd`
**Related:** [pterodactyl-test-blueprint.md](./pterodactyl-test-blueprint.md), [pterodactyl-adding-extensions.md](./pterodactyl-adding-extensions.md), [pterodactyl-ace.md](./pterodactyl-ace.md)

---

## 1. Versions

| Component | Today | Target | Notes |
|---|---|---|---|
| Panel | Pterodactyl 1.15.2 + Blueprint beta-2026-08 | **Hydrodactyl v6.4.2** (latest; `v6.4.1-hotfix` is the same commit) | Laravel 13, PHP 8.4, React 19 |
| Daemon | Pterodactyl Wings **1.13.4** | **unchanged: Wings 1.13.4** | see below |
| DB / cache | MariaDB 12.3.3, Valkey 8.1 | unchanged | |

**Wings.** Hydrodactyl drives three daemons per node (`nodes.daemonType`): stock
Pterodactyl Wings, pyrohost Elytra (v1.4.0) and Calagopus Wings (Rust rewrite,
`release-1.2.7` published today). Upstream made stock Wings the default again
(migration `2026_08_29_000002_set_default_node_daemon_to_wings`, "swap Elytra for
vanilla Wings"), and the migration sets our two nodes to `wings`. We already run
the newest Wings release (1.13.4, 2026-10-14), so **no node changes are needed and no
game-server data moves**. Elytra/Calagopus would mean a new daemon, config and
backup format on crux/elara for no feature we use. Every addon below works through
the daemon-agnostic repositories, so revisit only if upstream drops Wings.

## 2. Extensions: what replaced what

Hydrodactyl cannot run Blueprint extensions. All four are rebuilt as native addons in
[`plugins/hydrodactyl`](../plugins/hydrodactyl), wired in by a 19-line hook patch
(`patches/0001-homelab-addon-hooks.patch`) plus `install-addons.sh`.

| Blueprint extension | Hydrodactyl replacement | Data |
|---|---|---|
| `sociallogin` + Zitadel patches | `app/Addons/Sso`: native OIDC code flow (PKCE, state, nonce) against Zitadel; "Sign in with Zitadel" on the login page; Account → Linked Accounts; Extensions → Single Sign-On | `social_providers` / `social_connections` and the `sociallogin::*` settings are reused as-is. Callback URL `/extensions/sociallogin/callback` is unchanged, so the Zitadel app needs no change |
| `dnsrecords` | The extension's PHP (flake input) at its old namespace + new routes and a React admin tab (Servers → DNS) and settings page (Extensions → DNS Records) | `dnsrecords_*` tables untouched |
| `portforward` (router) | Same approach: the extension's PHP + React tab (Servers → Port Forward) and settings page | `portforward_*` tables untouched |
| `minecraft-tools` | `app/Addons/Minecraft`: server page **Minecraft** (Version, Plugins & Mods, Players, server.properties, Server icon, Modpacks) + Hydrodactyl's native plugin/mod marketplace | `minecraft_tools_*` tables reused (all were empty) |

Things that changed on the way (worth knowing):

- **minecraft-tools was a stub.** The deployed legacy port only recorded actions in
  the panel DB ("requires Wings integration which is not enabled") and picked the
  user's *first* server. All of it now acts on the server through the daemon:
  - version switch edits the egg variables and can reinstall;
  - enable/disable renames `.jar` ↔ `.jar.disabled`;
  - player actions are console commands;
  - `server.properties` is edited in place, with backups;
  - icon uploads are normalised to a 64×64 PNG;
  - modpacks install from Modrinth `.mrpack` and can be removed again.
- **Security fix:** the DNS extension's client routes ran through its admin adapter
  (`isAdmin: true`, no ownership check). They now live under
  `/api/client/servers/{server}/dns` behind Hydrodactyl's server-access middleware and
  subuser permissions. Prod has `client_subdomain_policy = never`.
- **SSO hardening:** linking a new Zitadel identity to an existing account by email now
  requires `email_verified`. A userinfo response without a groups/roles claim leaves
  `root_admin` alone instead of demoting.
- Plugin/mod search and download is Hydrodactyl's own **Installer** page. It needs egg
  features like `mod/fabric`, which our eggs lacked; the configure unit adds them
  (`homelab.panel.eggLoaderFeatures`).

## 3. Verification done (2026-10-25)

Test setup:
- **Data:** a throwaway MariaDB 12.3.3 loaded with a dump of the prod panel DB.
  DNS and port forwarding were forced to dry-run.
- **Panel:** the Nix-built panel, plus the runtime image itself.
- **Wings:** the real nodes, read-only. Writes went to a recording fake daemon.

Production was not modified.

- **Migration:** all 40 pending Hydrodactyl migrations ran cleanly on the prod copy.
  Servers, users, allocations, backups and extension rows were all unchanged.
  Nodes came out as `daemonType = wings`.
- **SSO:**
  - Real Zitadel accepted the generated authorize request (client, prod redirect URI,
    scopes), and the stored client secret decrypts with the prod `APP_KEY`.
  - Callback guards work for expired, forged-state and denied responses.
  - With Zitadel stubbed, these were checked: existing link, admin promote and demote,
    missing claim, unverified vs verified email, auto-register.
- **DNS (dry-run):**
  - Settings round-trip leaves every stored value byte-identical.
  - Live Cloudflare and Technitium record listing works.
  - Subdomain check, SRV profile save/sync and record create are logged as dry-run
    for both providers.
  - The client route returns 404 for a non-owner; admin routes return 403 for
    non-admins.
- **Port forward (dry-run):** settings round-trip is identical; the overview matches
  prod; forward and remove generate the right IOS `ip nat` lines.
- **Minecraft (Purpur, Fabric, NeoForge):**
  - Live versions/builds from Paper Fill, Purpur, Fabric meta and NeoForge maven.
  - Plugin/mod listings, players from the JSON lists, `server.properties` and icon
    reads all work.
  - Every write path was checked through the recording daemon: toggle, delete,
    properties save/backup/restore, all seven player commands, icon
    upload/delete/restore, version switch + reinstall.
  - A full `.mrpack` install pulled 17 files from `cdn.modrinth.com` and wrote 23
    overrides; removal deleted all 40 recorded files.
  - Input guards rejected 9 attack/invalid cases.
- **Runtime image, against the copy:**
  - First start: DB dump → sync over a fake old panel (`storage/` kept, `.blueprint`
    removed) → migrate → config/route/view/event caches → php-fpm, queue worker,
    scheduler.
  - Served real requests over FastCGI.
  - A restart skipped the dump and re-sync.
- **Not verified:**
  - Visual rendering of the new pages (typecheck and Vite build only).
  - A real Zitadel login round-trip.
  - Real writes to a game server.
  - Router SSH `test-connection` (unchanged code).

**Extension parity, re-checked 2026-10-25 on the ace-test node.** Both Pterodactyl
panels ran exactly `dnsrecords`, `portforward`, `sociallogin` and `minecraft-tools`
(plus Blueprint itself), and all four are covered. Two Hydrodactyl incompatibilities
in the reused extension PHP only showed up with a real node and were fixed in
`AddonsServiceProvider`:
- Hydrodactyl's `Server` model no longer maps its model events to
  `Pterodactyl\Events\Server\{Deleting,Updated}`, so on server delete the DNS cleanup
  and NAT removal never ran, and DNS's allocation-change SRV update never ran either.
  These are now bridged, unless upstream dispatches them again.
- portforward's `PluginContextFactory` is declared inside `PluginContext.php`, which
  PSR-4 can't load. Under Blueprint that file happened to be loaded already; on
  Hydrodactyl `ApplyNatJob`/`RemoveNatJob` failed. Now loaded explicitly.

Proven in dry-run against the test node:
- The NAT rule is removed on server delete.
- SRV records update on an allocation change.
- Admin DNS hostname/SRV/records and port-forward forward/remove all work.

Not provable in dry-run: DNS record deletion on server delete. Nothing exists at the
providers to delete, and its `dns-records-deleted` log goes to a
`plugin_activity_logs` table that never existed. It runs on the same bridged event as
the NAT removal. Known gap: only Zitadel is ported from sociallogin's provider list,
since it was the only one configured.

Bugs found and fixed during testing:
- `/extensions/*` was swallowed by the SPA catch-all (provider order).
- Client routes lost their auth middleware (`middleware()` called twice).
- Shared throttle buckets; switched to named per-user+route limiters.
- 500 on unverified email collisions.
- Wings 1.13 returns 500, not 404, for missing files.
- Loose version strings were accepted.
- The PHP ini scan dir would have dropped every extension.

## 4. Nix wiring

- `nixos/containers/hydrodactyl-panel.nix`: builds the panel. It uses the release
  tarball (pinned hash), the addons, Composer vendor and the pnpm/Vite frontend, and
  needs no network at runtime.
- `nixos/containers/hydrodactyl-docker.nix`: the runtime image. On start it:
  - syncs code into `/var/www/pterodactyl`, keeping `.env`, `storage/` and
    `bootstrap/cache`;
  - on the **first** start over Pterodactyl, dumps the DB plus `.env` into
    `storage/hydrodactyl-migration/`;
  - migrates, caches, and runs php-fpm, the queue worker and the scheduler.
- `nixos/containers/hydrodactyl.nix`: the switch, `homelab.panel.{prod,test}.flavor`
  (default `pterodactyl`). Setting a panel to `hydrodactyl`:
  - swaps the container image;
  - turns off the Blueprint, stock-reset and old SSO units;
  - enforces `APP_LOCALE=en-US` and `ZITADEL_*` in `.env`;
  - runs `hydrodactyl[-test]-configure` (Zitadel provider from sops, egg loader
    features) after the existing extension seeders, which now work with either flavor.
- The test panel gets its own code dir `/pterodactyl-test/html`. The dev checkout
  `/home/prestonh/Projects/panel` is no longer mounted.
- `systemctl start hydrodactyl-test-load-prod` (manual only) copies the prod DB into
  the test panel with DNS/port forwarding forced to dry-run. The test panel keeps its
  own `APP_KEY`, so it can never decrypt the node tokens and drive production servers.

### Throwaway Wings node (test panel)

`homelab.panel.test.wingsNode.enable` ([hydrodactyl-test-node.nix](../nixos/containers/hydrodactyl-test-node.nix)), on ace:

- **Wings:** 1.13.4, the same package as crux and elara, running as `wings-test` on
  127.0.0.1:8080.
- **Docker:** a pinned `docker:28.5.1-dind` container. Everything Wings hands to Docker
  lives under `/var/lib/wings-test`, at the same path in dind. That includes
  `machine_id`, which Wings 1.13 bind-mounts into every server.
- **Routing:** the node's FQDN is `test.panel.prestonhager.com` on 443. Caddy routes
  only Wings' paths (`/api/servers`, `/api/system`, `/download`, `/upload`, …) to it,
  so no DNS record, certificate or firewall port is needed. Those paths also accept
  `10.88.0.0/16`, because the panel container calls them through the pod's
  `test.panel → host-gateway` mapping. Every Wings call still needs its token.
- **Registration:** `wings-test-config` registers location `ace-test`, node `ace-test`
  and ten `0.0.0.0` allocations (25600–25609) through Hydrodactyl's own
  NodeCreationService. It then writes `/var/lib/wings-test/config.yml` (root, 0600).
- **Game ports** are bound inside dind only, so players can't join. The node is for
  panel testing.
- **Only node:** the production nodes and their servers are removed from the test
  panel. `hydrodactyl-test-load-prod` strips them again after every copy, with plain
  SQL so nothing calls their Wings or database hosts, and then re-registers `ace-test`.
  The DNS/port-forward node maps point `ace-test`'s id at ace (`test.panel…`,
  `192.168.5.5`) instead of whichever production node shared that id.

Verified 2026-10-25 on server `13dc5324` ("Hydrodactyl Test (Purpur)", owned by user
1), all through panel → Caddy → Wings → dind:
- Egg install.
- File write/read (`eula.txt`).
- Power start → `running`.
- Console command over the REST API, and the **browser websocket** (auth, status, live
  console output).
- Minecraft page: whitelist/op commands reflected in Players, `server.properties` save
  read back from disk, icon upload, plugin disable/re-enable.
- Backup creation.

## 5. Cutover

**Done 2026-10-26 (UTC).**
- **Backups:** an independent dump, a tarball of `/pterodactyl/html` and `.env` were taken in `/var/backups/hydrodactyl-cutover-20261026T010714Z` first. The entrypoint also wrote its own dump to `/pterodactyl/html/storage/hydrodactyl-migration/`.
- **Migration:** the panel was down for about 2 minutes. Game servers were untouched (uptimes unchanged). All 40 migrations ran, and all 52 pre-existing tables kept identical row counts (`counts-before.txt` / `counts-after.txt`).
- **Checks:** the following were verified read-only on prod:
  - both nodes on Wings 1.13.4;
  - all 8 servers' live state;
  - console credentials, files and backups;
  - the Minecraft page on all three Minecraft servers;
  - the admin API, DNS (live), port forward (live), SSO settings, and Zitadel accepting the prod callback.


1. **Test panel:** set `homelab.panel.test.flavor = "hydrodactyl";` and rebuild ace.
   Optionally run `hydrodactyl-test-load-prod`. Click through every addon page in a
   browser, and do one real Zitadel login (test.panel's callback must be registered
   in Zitadel, as it was for Blueprint).
2. **Prod, in a maintenance window:**
   - Game servers keep running; only the panel restarts.
   - Set `homelab.panel.prod.flavor = "hydrodactyl";` and rebuild ace.
   - Watch `journalctl -u podman-pterodactyl -u hydrodactyl-configure`.
   - The entrypoint writes the pre-migration dump to
     `/pterodactyl/html/storage/hydrodactyl-migration/`.
3. **Smoke test:**
   - SSO login, and both nodes green.
   - Console on one server per node.
   - The DNS and Port Forward tabs on a server.
   - The Minecraft page on all three Minecraft servers.
4. **Rollback:**
   - Set the flavor back to `pterodactyl` and stop `podman-pterodactyl`.
   - Restore the dump from `storage/hydrodactyl-migration/` into `pterodactyl-db`.
   - Restore `/pterodactyl/html` from backup; the Blueprint install units rebuild it
     from stock + extensions.
   - Rebuild. Wings needs nothing.
5. **After a stable week:** delete the Blueprint modules
   (`pterodactyl-blueprint*.nix`, `*-stock-reset.nix`, `*-sso.nix`,
   `blueprint-plugins.nix`) and the `blueprint-framework` / `pterodactyl-minecraft-tools`
   flake inputs. Keep `pterodactyl-dns-records` and `pterodactyl-port-forward`, since
   the addons build from them.

Upgrading Hydrodactyl later: bump `version` and the tarball hash in
`hydrodactyl-panel.nix`, re-apply the hook patch (touches `config/app.php`,
`AdminApp.tsx`, `ServerLayout.tsx`, `LoginContainer.tsx`, `UnifiedRouter.tsx`,
`routes.ts`), refresh `pnpmDeps.hash` and `vendorHash`, and test on the test panel.

Sources: [Hydrodactyl](https://github.com/BlueprintFramework/hydrodactyl),
[docs](https://hydrodactyl.dev/docs/hydrodactyl),
[native→native guide](https://hydrodactyl.dev/docs/hydrodactyl/migrations/native-to-native),
[Introducing Hydrodactyl](https://blueprint.zip/blog/introducing-hydrodactyl),
[pterodactyl/wings releases](https://github.com/pterodactyl/wings/releases),
[pyrohost/elytra](https://github.com/pyrohost/elytra), [calagopus/wings](https://github.com/calagopus/wings).
