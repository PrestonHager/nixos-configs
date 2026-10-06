# Animal Search on ace — staging + production

Deployment topology for the NMSU-CS-CS371 group project (Astro SSR + MariaDB),
renamed from `adopter-central` on 2026-10-04.

Two fully independent environments run side by side on `ace`. Each has its own
Podman pod, MariaDB instance, database, credentials, and release tree. A bug or
a bad migration in staging cannot reach production data.

| | production | staging |
|---|---|---|
| Hostname | `animal-search.prestonhager.com` | `staging.animal-search.prestonhager.com` |
| App port (loopback) | `127.0.0.1:4322` | `127.0.0.1:4323` |
| Pod | `animal-search-production-pod` | `animal-search-staging-pod` |
| Containers | `animal-search-production-db`, `animal-search-production-app` | `animal-search-staging-db`, `animal-search-staging-app` |
| Data root | `/stor/animal-search/production` | `/stor/animal-search/staging` |
| Database | `animal_search` | `animal_search_staging` |
| Secrets | `animal-search-production-{db,app}-env` | `animal-search-staging-{db,app}-env` |

## NixOS modules

- `nixos/containers/animal-search.nix` — pods, containers, tmpfiles, users,
  bootstrap/release-check units. Enabled in `hosts/ace/default.nix` via
  `services.animalSearch.enable`.
- `nixos/caddy/animal-search.nix` — the two reverse-proxy vhosts. Imported by
  `nixos/caddy/default.nix`.

Environment names are data, not code. `services.animalSearch.environments` is an
attrset, and the attribute name (`production`, `staging`) becomes part of the pod
name, container names, systemd unit names, the `/stor/animal-search/<name>` tree
and the SOPS key names. Adding a third environment is one attrset entry:

```nix
services.animalSearch.environments.canary = { port = 4324; };
```

## Ports are loopback-only

Each pod is created with `-p 127.0.0.1:<port>:<port>`:

```
podman pod create --name animal-search-production-pod --memory 3G --cpus 2 \
  -p 127.0.0.1:4322:4322
```

Consequences worth knowing:

- The ports MUST be declared at `podman pod create` time. Podman rejects
  container-level networking for containers that belong to a pod, so
  `ports = [ ... ]` on the container is a hard failure, not a warning.
- `4322`/`4323` are deliberately **not** in `networking.firewall.allowedTCPPorts`.
  Nothing but Caddy can reach them.
- The app and MariaDB share the pod network namespace, so the app reaches its
  database at `127.0.0.1:3306` — no published database port.

## Reverse proxies

`nixos/caddy/animal-search.nix` proxies the two hostnames to the loopback ports
and keeps both sites LAN-only with the same `@lan` matcher used by
`serverdocs.nix`:

```
@lan remote_ip 192.168.5.0/24 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12
handle @lan { reverse_proxy 127.0.0.1:4322 { ... } }
handle      { respond "... is LAN-only." 403 }
```

`127.0.0.1` is deliberately not in that list, so on-box `curl
https://animal-search.prestonhager.com/` returns `403` — same as
`serverdocs.prestonhager.com`. To test from the host, go through the LAN address:

```bash
curl --resolve animal-search.prestonhager.com:443:192.168.5.5 \
  https://animal-search.prestonhager.com/
```

Plain `http://` returns a `308` to `https://`. Certificates come from the
Cloudflare ACME DNS-01 challenge (`nixos/caddy/acme-dns.nix`), so no inbound
port and no DNS A record are needed for issuance.

## DNS

The public apex `prestonhager.com` is on Cloudflare (`felipe.ns.cloudflare.com`),
but LAN clients resolve these names through Technitium on `ace`. Records live in
the Technitium zone `prestonhager.com` and point straight at the host:

| Name | Type | Value | TTL |
|---|---|---|---|
| `animal-search.prestonhager.com` | A | `192.168.5.5` | 3600 |
| `staging.animal-search.prestonhager.com` | A | `192.168.5.5` | 3600 |

Many sibling records (`jellyfin`, `serverdocs`) are CNAMEs to
`ace.internal.prestonhager.com` instead; a direct A record was used here because
it is one hop shorter and the target is the host itself. Both resolve to the
same address.

Technitium's DNS API on this host is **not** the `/api/dns/...` prefix used by
older documentation. This build (15.6) serves:

- Auth: `POST /api/user/login` (form body `user`, `pass`) → JSON `token`, then
  send `Authorization: Bearer <token>`.
- Zones: `POST /api/zones/list` (`pageNumber`, `zonesPerPage`).
- Records: `POST /api/zones/records/get`, `POST /api/zones/records/add`,
  `POST /api/zones/records/delete`, `POST /api/zones/records/update`.

Two gotchas that cost real time:

1. `domain` must be the **fully qualified** name. Passing the relative label
   (`animal-search`) fails with
   `The domain name 'animal-search' does not belong to the zone: prestonhager.com`.
2. Query-string auth (`?token=...`) returns `404` with an empty body. Use the
   `Authorization` header, as `nixos/containers/technitium-protocols.nix` does.

Working example:

```bash
API=http://127.0.0.1:5380
TOKEN=$(curl -sf -X POST "$API/api/user/login" \
  --data-urlencode "user=admin" \
  --data-urlencode "pass=$(cat /stor/technitium/secrets/admin-password)" | jq -r .token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN" "$API/api/zones/records/add" \
  --data-urlencode "zone=prestonhager.com" \
  --data-urlencode "domain=animal-search.prestonhager.com" \
  --data-urlencode "type=A" \
  --data-urlencode "ipAddress=192.168.5.5" \
  --data-urlencode "ttl=3600" \
  --data-urlencode "overwrite=true"
```

Note `overwrite=true` makes this idempotent: re-running updates the record
instead of failing. Technitium listens on `192.168.5.5:53` and
`127.0.0.1:5353` — **not** `127.0.0.1:53`.

`nixos/local-service-hosts.nix` also maps both hostnames to `127.0.0.1` in
`/etc/hosts` so on-box tools skip DNS entirely.

## Release layout

```
/stor/animal-search/production/
├── current -> releases/<sha>        # bind-mounted read-only at /app
├── releases/
│   ├── bootstrap/                   # installed by Nix on first activation
│   └── <sha>/                       # one directory per successful deploy
└── mariadb/                         # database files
```

A deploy is: write `releases/<sha>`, run migrations, repoint `current`, restart
the app container. Because `current` is a symlink resolved at container start,
rollback is a symlink swap plus a restart, and old releases stay on disk for
`deploy.yml`'s prune step to collect.

`animal-search-<env>-bootstrap.service` installs a placeholder `entry.mjs` that
answers `503` with a JSON body naming the environment, so a fresh host is never
left with a broken vhost and the reason is obvious in the logs.
`animal-search-<env>-release-check.service` fails loudly if `current` has no
entrypoint.

## Runtime image

`docker.io/library/node:22-slim`, **not** `alpine`. Astro pulls in `sharp` as a
production transitive dependency and its native binaries are glibc-only. The
release is built on the glibc AL2023 runner, so the runtime must be glibc too.

Containers run as numeric uids with no in-image `/etc/passwd` lookup:
`animal-search-db` is `10000:10000` on the host and MariaDB is launched as
`10000:10000` inside the container. `animal-search-app` is `10001:10001`.

These ids are pinned in the `10000+` band deliberately. They were originally
`999:999` and `1002:1002`, which collided with ids NixOS hands out on ace: gid
`999` is `nscd` and uid `999` is shared with `nm-iodine`. Because the MariaDB
data directories are `0770`, that collision gave the `nscd` daemon group-write
access to both production and staging database files. ace's allocator-assigned
ids occupy roughly the `300-1002` band (`nixbld` is pinned at `30001+`), so
`10000+` stays clear of it as more services are added.

Changing a uid or gid in NixOS does not happen automatically — activation logs
`not applying GID change ...` and leaves `/etc/group` alone. To move these, edit
`/etc/passwd` and `/etc/group` directly and `chown -R` the data trees in the same
pass. Do not use `usermod -u`: it also chowns every file owned by the old uid,
and the old uid `999` belongs to `nm-iodine`.

## Deploying

`.github/workflows/deploy.yml` in
`NMSU-CS-CS371/software-development-semester-project-group-5` builds the app on
the `adopter-central` self-hosted runner, migrates, activates, smoke-tests, and
rolls back on failure. It triggers on pushes to `main` and `workflow_dispatch`
only — never on pull requests, so a branch cannot deploy. `main` additionally
requires one approving PR review.

See `db/DEPLOYMENT.md` in the app repo for the workflow-side reference.

## Operating

```bash
# unit + pod state
systemctl status 'animal-search-*' podman-animal-search-production-app
podman pod ls | grep animal-search

# logs
journalctl -u podman-animal-search-production-app -f
podman logs -f animal-search-production-db

# database access (as the app user, from the db container)
PW=$(sed -n 's/^MARIADB_PASSWORD=//p' /run/secrets/animal-search-production-db-env)
podman exec animal-search-production-db \
  mariadb -uanimal_search -p"$PW" animal_search

# switch an environment back to the placeholder / previous release
ln -sfn /stor/animal-search/production/releases/<sha> \
        /stor/animal-search/production/current
systemctl restart podman-animal-search-production-app
```

## Rebuilding ace

This host is memory-bound and has frozen under unconstrained rebuilds (see
`ace-rebuild-freeze-rca.md`). Always use the constrained form:

```bash
cd /etc/nixos
NIX_BUILD_CORES=2 nixos-rebuild switch --flake .#ace \
  -j 2 --option max-jobs 2 --option cores 2 --no-update-lock-file
```

`switch-to-configuration` may still exit `4` because of stale
`podman-github-runner-ace-*` / `ace-ep-*` units from the older ephemeral runner
sets. That is unrelated to this stack — check
`systemctl show nixos-rebuild-switch-to-configuration.service -p Result` and the
Animal Search units rather than trusting the exit code.

## Renamed from adopter-central

`adopter-central` used a single environment on port `4321`
(`/stor/adopter-central`, `adopter_central` database). Port `4321` is now free.

- Old module, pod, containers, systemd units and data tree are gone.
  `/stor/adopter-central` was removed; it only ever held a placeholder.
- `secrets/containers/adopter-central.yaml` is retired in `nix-secrets` but was
  left in place rather than deleted. Remove it once you are sure nothing needs
  to roll back.
- The GitHub runner is still named `adopter-central` (GitHub runner names are
  immutable without re-registration). Only the workload was renamed.
