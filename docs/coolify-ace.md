# Coolify on ace

[Coolify](https://coolify.io) is the app hosting panel for class and side projects. The dashboard runs on ace; apps run on **mars**, which Coolify reaches over SSH. crux was a deploy server until 2026-10-20 and has been removed from Coolify.

| | |
|---|---|
| Dashboard | https://coolify.prestonhager.com (LAN, tailnet and WireGuard only; see [Access](#access)) |
| Apps | `https://<name>.apps.prestonhager.com`, or any other `prestonhager.com` name (see [Routing](#routing-traffic-to-apps)) |
| Version | Coolify 4.4.6 (pinned by digest) |
| Deploy servers | mars (192.168.5.15), Coolify proxy (Traefik) on :80; more nodes via `nodes` in `coolify-edge.nix` (see [Adding a node](#adding-a-deploy-server)) |
| Config | `nixos/containers/coolify.nix`, `nixos/containers/coolify-sso.nix`, `nixos/containers/coolify-edge.nix`, `nixos/caddy/coolify.nix`, `nixos/coolify-node.nix` (mars) |
| Secrets | `nixos-secrets/secrets/containers/coolify.yaml`; SMTP password from `nextcloud-environment`; router key `pterodactyl-router-ssh-key`; Cloudflare token `cloudflare-acme-env`; Technitium admin password |

## How it fits together

```mermaid
flowchart LR
  U[Browser] -->|HTTPS| C[Caddy on ace]
  C -->|coolify.prestonhager.com| D[coolify app :8000/6001/6002]
  D --- P[(coolify-db)]
  D --- R[(coolify-redis)]
  D -->|SSH root, own key| X[mars Docker]
  C -->|*.apps + unclaimed hostnames, HTTP, per routes.caddy| T[Traefik coolify-proxy on the app's node :80]
  T --> A[app containers]
  C -. on-demand TLS ask .-> E[coolify-edge-ask :9180]
  E -. reads .-> P
  N[coolify-edge-nat timer] -. reads .-> P
  N -->|SSH pterofwd| RT[Astracap static NAT]
  DN[coolify-edge-dns timer] -. reads .-> P
  DN -->|CNAMEs| CF[Cloudflare + Technitium]
  RO[coolify-edge-routes timer] -. reads .-> P
  RO -->|routes.caddy + reload| C
  RT -->|published ports| A
  K[Keycloak realm homelab] -. OIDC .- D
  KR[coolify-keycloak-roles timer] -. coolify_* groups .-> K
  KR -->|root team roles| P
```

- **TLS** terminates on ace's Caddy with Cloudflare DNS-01 certificates (the `*.apps` wildcard needs DNS-01). Coolify's proxy on mars only serves HTTP on :80, and mars's `coolify-ingress` chain (`nixos/coolify-node.nix`) drops new connections from private sources other than ace→:80, while app containers cannot reach the LAN ([mars](../poweredge/mars.md)). Traefik trusts `X-Forwarded-*` from ace (`--entrypoints.http.forwardedHeaders.trustedIPs=192.168.5.5/32` in the proxy configuration), so apps see `https`.
- **DNS**: Cloudflare CNAMEs `coolify` and `*.apps` → `ip1.lc1.nm.us.prestonhager.com`; Technitium has the same names → ace for the LAN (`technitium-zones.nix`).
- **Containers** run on the `coolify` Podman network (not a pod), so restarting one of them never strands the others in a dead network namespace.

## Access

`nixos/caddy/coolify.nix` splits `coolify.prestonhager.com` by path:

| Path | Who can reach it | Why |
|---|---|---|
| `/webhooks/*` | anyone | GitHub (App and manual webhooks) must reach it to trigger deploys; Coolify checks the webhook secret |
| `/api/*` | LAN, tailnet, WireGuard, and GitHub-hosted Actions runners | token-authenticated API. Animal Search's deploy workflow runs on GitHub-hosted runners and calls it (see [GitHub Actions access to the API](#github-actions-access-to-the-api)). `githubActionsApi = false` in `nixos/caddy/coolify.nix` makes it LAN-only again |
| `/app/*` (realtime), `/terminal/ws` (web terminal), everything else (dashboard, login, Keycloak callback `/auth/oidc/callback`) | LAN, tailnet, WireGuard | admin surface |

"LAN, tailnet, WireGuard" is the shared `lanOnly` guard in `nixos/caddy/lib.nix` (`192.168.5.0/24`, `100.64.0.0/10` and the tailnet IPv6 range, `192.168.20.0/24`, loopback); everyone else gets 403. Off-site, connect to the tailnet or the VPN first, and make sure the name resolves to ace's LAN address (Technitium) rather than the public IP. Apps (`*.apps.prestonhager.com` and the on-demand catch-all) stay public.

### GitHub Actions access to the API

The GitHub runner ranges are the `actions` list from `https://api.github.com/meta` (about 7,000 IPv4 and IPv6 CIDRs, changed often), so they are fetched rather than written into Nix:

- `coolify-github-actions-ips.service` (on boot, on every switch, and every 6 hours from its timer) downloads the list. It rejects a list with fewer than 100 entries or anything that is not a CIDR, runs `caddy validate` on the generated matcher, then writes `/var/lib/coolify-github-actions/matcher.caddy` (`@github_actions { remote_ip … }`) and reloads Caddy if the list changed. On any failure it keeps the current file, and the unit fails.
- The vhost `import`s that file. On a fresh host, tmpfiles first creates it holding only `192.0.2.0/32` (TEST-NET-1), so Caddy starts and the API stays closed until the first successful fetch.

These are shared GitHub/Azure addresses: any GitHub Actions job, in any repository, connects from them. The allowlist only keeps the rest of the internet away; the API token still does the authorizing, so keep tokens scoped (`deploy`, `read`, `write`; add `delete` only if a workflow deletes through the API; never `root`) and revoke unused ones in **Keys & Tokens**. Since Coolify 4.6, `write` no longer includes deletes; the 4.6 migration gave existing `write` tokens `delete` so nothing broke, so remove it from tokens that never delete. Registry check and logout need `deploy`. Self-hosted runners on the LAN already match the LAN rule.

```bash
systemctl start coolify-github-actions-ips    # refresh now
journalctl -u coolify-github-actions-ips -n 5 # "<n> ranges, unchanged|updated"
grep -c remote_ip /var/lib/coolify-github-actions/matcher.caddy
```

Registration is pinned off by `coolify-instance-settings` (a UI toggle is reverted on the next run; Coolify itself also turns it off after creating the first user). The Keycloak (`oidc`) provider has its own *allow registration* switch, which `coolify-keycloak-oauth` keeps off too: accounts are created by the role sync, not by signing in. See [Signing in and adding users](#signing-in-and-adding-users).

## Routing traffic to apps

Everything an app in Coolify needs from outside (DNS, TLS, proxying, port forwards) is derived from what is configured in Coolify; there is nothing to add in Nix or by hand per app.

**Web (HTTP/HTTPS).** `nixos/caddy/coolify.nix` has three sites for apps:

| Caddy site | Goes to | Certificate |
|---|---|---|
| `*.apps.prestonhager.com` | the app's node :80 (default mars) | wildcard (DNS-01) |
| `https://` (catch-all) | the app's node :80 (default mars) | issued on demand, per hostname |
| `http://` (catch-all) | 308 redirect to HTTPS | — |

Caddy always prefers the most specific site, so the catch-alls only see hostnames that none of ace's own services claim. Before Caddy issues an on-demand certificate it asks `coolify-edge-ask` (`127.0.0.1:9180/ask?domain=…`), which says yes only when an application, preview or service of the Root Team (`COOLIFY_EDGE_TEAM_IDS`) uses that hostname, it is inside `COOLIFY_EDGE_ZONES` (`prestonhager.com`), **and** it is not reserved:

- `COOLIFY_EDGE_DENY_HOSTS`: every hostname ace's own Caddy serves (generated from `services.caddy.virtualHosts`), and the zone apex;
- `COOLIFY_EDGE_DENY_LABELS`: any name with a sensitive label below the zone, such as `login`, `sso`, `auth`, `admin`, `vault`, `mail`, `www`, `zitadel`, `panel`, `cloud`, `grafana`, `coolify`, `dns`, `wg` or `prometheus` (full list in `coolify-edge.nix`), so `admin.group5.prestonhager.com` is refused too.

Refused names also get no DNS records. The ask endpoint remembers unknown names for 30 seconds and re-reads Coolify's database at most every 5 seconds on a miss, so a flood of random SNI names cannot run a database query per request. Any other name fails the TLS handshake, so stray SNI never reaches Let's Encrypt. Certificates use the same Cloudflare DNS-01 token as everything else, so only names in Cloudflare zones that token can edit work.

**Which node.** Both app sites `import /var/lib/coolify-edge-routes/routes.caddy` and proxy to `{coolify_upstream}`. `coolify-edge-routes` (timer, every minute) writes that file from Coolify's database: a Caddy `map` from each hostname to `<server ip>:80` of the server the app, preview or service is deployed on (application → destination → server). Hostnames on the default node (`defaultNode`, mars) are not listed and use the map's `default` line. The new file is checked with `caddy validate` and installed only when it changed; then Caddy reloads, and every route change is logged at warning level. A hostname is left on the default node, with a warning, when it is used on two servers, when its server is not in `nodes` (Caddy only ever proxies to servers listed there), or when it is a wildcard. A new app on another node can get the default node's 404 for up to a minute until the map catches up (`systemctl start coolify-edge-routes` to sync now; `edge-sync.py routes --dry-run` prints the map). Coolify's "additional servers" for one app are not used: an app goes to its main server.

Coolify's own **DNS validation** (which wants an A record for mars on every app domain, and otherwise shows the domain as mismatched) is pinned off by `coolify-instance-settings`: app names resolve to ace on purpose. After changing an app's domain, **redeploy** it: Traefik routes on container labels, which are only written when the container is created, so until then the new name gets a 503 from Traefik.

To give an app a custom name such as `group5.prestonhager.com`, set the app's domain in Coolify to `http://group5.prestonhager.com` (always `http://`; TLS is ace's job) and deploy. Within a minute `coolify-edge-dns` creates:

- **Cloudflare:** CNAME `group5` → `ip1.lc1.nm.us.prestonhager.com`, DNS only, comment `managed by coolify-edge (nixos-configs)`. It uses the Caddy DNS-01 token (`cloudflare-acme-env`).
- **Technitium (LAN):** CNAME `group5` → `ace.internal.prestonhager.com`. Technitium is authoritative for `prestonhager.com` on the LAN, so without it LAN clients could not resolve the name. `technitium-sync-zones` re-imports the zone when the Nix zone file changes, which drops these records; the job re-adds them within 15 minutes (or run `systemctl start coolify-edge-dns`).

When the domain is removed from Coolify, both records are deleted. Only records the job created are ever deleted (by comment in Cloudflare, by its state file in Technitium). A name that already has other records, such as `grafana`, is left alone and logged as a conflict. `*.apps.prestonhager.com` names are skipped because the wildcard records already cover them. The first HTTPS request to a new name waits a few seconds for the certificate.

**Other ports (TCP/UDP).** `coolify-edge-nat` (timer, every minute) forwards from the WAN every host port that Coolify publishes on mars:

- an application's **Ports Mappings** (`8080:80`, `25565:25565/udp`, `27000-27010:27000-27010`; mappings bound to `127.0.0.1` are skipped), and
- only if `COOLIFY_EDGE_FORWARD_PUBLIC_DATABASES = "1"` (default off): a database with **Make it publicly available** (its public port) or its own port mappings. With the default, a public database is reachable from the LAN only.

Limits: a range wider than `COOLIFY_EDGE_MAX_RANGE` (20) ports is skipped, and if more than `COOLIFY_EDGE_MAX_PORTS` (50) ports would be forwarded in total the job refuses to change the router at all and the unit fails. Every NAT line it adds or removes is logged at warning priority (`journalctl -p warning -u coolify-edge-nat`).

It writes `ip nat inside source static <tcp|udp> 192.168.5.15 <port> interface GigabitEthernet0/0 <port>` on Astracap and removes `192.168.5.15` lines Coolify no longer wants. Lines for other inside addresses (ace's :80/:443, Hydrodactyl game ports) are never touched; a port already forwarded elsewhere is reported as a conflict and skipped. Ports in `COOLIFY_EDGE_BLOCKED_PORTS` are never forwarded: SSH, DNS, HTTP(S), DoT and the router's own ports, plus common mail, SMB, NFS, RDP, SNMP and LDAP ports and ace's admin ports (full list in `coolify-edge.nix`). The WAN port equals the host port. Rules live in running-config only (like the Hydrodactyl port-forward addon's); the timer re-checks the router every 15 minutes while any rule is wanted, so they come back after a router reboot. While no app publishes a port it never logs in to the router.

Docker Compose services (Coolify *Services* and the Docker Compose build pack) are not covered: their `ports:` are not stored in a column Coolify exposes. Publish such ports through an application's Ports Mappings instead.

The NAT job logs in as `pterofwd` with the Hydrodactyl port-forward key. That account must be allowed to run `show running-config` and `configure terminal` (see [Astracap](../shared/network-astracap.md#automation-account-pterofwd)).

```bash
journalctl -u coolify-edge-nat -n 20      # what it added/removed, conflicts
journalctl -u coolify-edge-dns -n 20      # CNAMEs added/removed, conflicts, refused names
journalctl -p warning -u 'coolify-edge-*' # only the changes (router/DNS) and refusals
journalctl -u coolify-edge-ask -f         # on-demand TLS decisions
cat /var/lib/coolify-edge/{nat,dns}.json  # last wanted sets
systemctl start coolify-edge-nat coolify-edge-dns   # sync now
```

To see what the job would do without touching the router: `systemctl cat coolify-edge-nat` for the environment, then run its `ExecStart` with `--dry-run`. `… edge-sync.py domains` lists the hostnames the ask endpoint accepts.

## Email

Coolify sends mail (password resets, invitations, deployment and server notifications) through the iCloud+ SMTP account that Nextcloud, Grafana and Zitadel use: `smtp.mail.me.com:587`, STARTTLS, user `prestonhager@icloud.com`, from `Coolify <admin@prestonhager.com>`. `coolify-email-settings.service` (`nixos/containers/coolify/email-settings.php`) writes this into Coolify's instance settings on every boot and switch, with the password taken from `SMTP_PASSWORD` in the `nextcloud-environment` secret, and sets the Root Team's email notifications to use the instance settings. Changing it in the UI is undone on the next run.

Which events mail out is chosen in Coolify → **Notifications** → **Email**; recipients are the team's members. Test with **Send Test Email** on that page.

## Signing in and adding users

Login is through Keycloak (**Keycloak** button on the login page): Coolify's generic OIDC provider against the `homelab` realm (`https://keycloak.prestonhager.com/realms/homelab`, client `coolify`, PKCE S256). Everything is in `nixos/containers/coolify-sso.nix`:

- `homelab.keycloak.clients.coolify` declares the client (callback `https://coolify.prestonhager.com/auth/oidc/callback`). Its secret is `KEYCLOAK_CLIENT_SECRET` in `coolify-keycloak-env` (`secrets/containers/coolify.yaml`); `keycloak-realm-sync` sets Keycloak to that value.
- `coolify-keycloak-oauth` (`coolify/oauth-setting.php`, every boot and switch) writes the client into Coolify's OAuth settings with *allow registration* off, and keeps the old Zitadel provider disabled.
- `coolify-keycloak-roles.timer` (every 5 minutes; `coolify/keycloak-role-sync.mjs` + `coolify/apply-roles.php`) reads the Keycloak groups through the admin API as the `homelab-config` service account and applies them to the Root Team:

| Keycloak group | Coolify |
|---|---|
| `coolify_admin` | Admin of the Root Team (servers, projects, deployments) |
| `coolify_member` | Member of the Root Team. Since Coolify 4.6 a member without access grants is read-only (view the team, no deploys); give grants in **Team → Members → Access**, or use `coolify_admin` |
| *(neither)* | Removed from the Root Team on the next sync; no account is created |

Users are matched by email. A group member with no Coolify account gets one (Root Team only, random password), and their first Keycloak login links to it. Keycloak lets every realm user authenticate, so this account is the gate: a login with no account is refused ("registration disabled"). Disabled Keycloak users and users with no email are skipped. Coolify only links a login whose `email_verified` is true, so the sync warns about members with an unverified email.

To add someone:

1. Create the user in Keycloak, or use an existing one ([docs/keycloak-users.md](keycloak-users.md)). Their email must be set and verified.
2. Admin console → Users → the user → **Groups** → **Join group** → `coolify_admin` or `coolify_member`.
3. Within 5 minutes the sync creates their account with the matching role (`systemctl start coolify-keycloak-roles` on ace does it now). They sign in at https://coolify.prestonhager.com (from the LAN, tailnet or VPN) with **Keycloak**.

To remove someone, take them out of the group. The next sync removes them from the Root Team. Their Coolify account and OIDC link stay, so they can still sign in, but they only see a personal team. Delete the account in **Settings → Users** to lock them out completely. The original owner account (preston@hagerfamily.com, user 0) is never changed by the sync.

**Zitadel migration (2026-11-04):** before the switch Coolify had one account, preston@hagerfamily.com (user 0, Root Team owner), linked to Zitadel. `coolify-keycloak-oauth` dropped the Zitadel identity links, because Coolify allows only one OAuth identity per account. The account, its teams and its role are unchanged; it links to Keycloak (prestonh, same verified email) on its first Keycloak login.

**Regression test:** `bash tests/sso/run.sh coolify` on ace. It puts `sso-regression` in the groups one by one, runs the sync, and logs in. It checks that login is refused with no group and lands on the dashboard as member, then checks admin, removal, and that the owner is untouched. It deletes the test account afterwards.

**Break-glass login:** the owner can also sign in with email and password. The password is `ROOT_USER_PASSWORD` in `coolify-env`:

```bash
cd ~/nixos-secrets   # on a machine with the root age key
sops -d --extract '["coolify-env"]' secrets/containers/coolify.yaml | grep ROOT_USER_PASSWORD
```

Public registration is off (Settings → Configuration) and pinned off by `coolify-instance-settings`. New accounts only come from the Keycloak group sync (step 3 above); the dashboard is not reachable from the internet in any case.

## Hosting the CS371 group 5 project

Repository: https://github.com/NMSU-CS-CS371/software-development-semester-project-group-5 (private).

**Current setup (Animal Search, 2026-10-25):** Coolify project **Animal Search**, two Docker Image apps on mars that run `ghcr.io/nmsu-cs-cs371/software-development-semester-project-group-5`. The repo's `deploy-coolify.yml` builds and pushes that image on GitHub-hosted runners, pins the app to the commit's tag through the API and triggers the deploy. mars's server **Wildcard Domain** is `http://apps.prestonhager.com`, so new apps default to `http://<uuid>.apps.prestonhager.com`.

| Environment | App uuid (`COOLIFY_APP_UUID`) | URL | Image tag |
|---|---|---|---|
| staging | `til4tnx6t6nf05gia9lhydwn` | https://staging.animal-search.apps.prestonhager.com | `staging`, then the commit SHA |
| production | `v50rlefzhzwuofnh9aj89bfm` | https://animal-search.apps.prestonhager.com | `production`, then the commit SHA |

Each environment also has its own MariaDB resource on mars (created 2026-10-25), `mariadb:11.4`, not public (no host port; reachable only on the `coolify` Docker network):

| Environment | Database resource | uuid (= `DB_HOST`) | `DB_NAME` | Backups (local on mars, keep 14) |
|---|---|---|---|---|
| staging | `animal-search-staging-db` | `vvk7rsqyudzbnlqtwlvb0vxk` | `animal_search_staging` | daily 03:30 UTC |
| production | `animal-search-production-db` | `d4qstbqgxnza1vd2s4ri255v` | `animal_search` | daily 03:00 UTC |

Both use user `animal_search` with a generated 64-character password (each database has its own). The apps get `DB_HOST`, `DB_PORT=3306`, `DB_USER`, `DB_PASSWORD` and `DB_NAME` as runtime-only environment variables (not build variables, so they never reach the image). Copy the values from the database's page in Coolify if they ever change. All Coolify apps share the `coolify` network, so staging can open a TCP connection to production's database: the separate credentials are what keep them apart. Dumps land in `/data/coolify/backups/databases/root-team-0/<name>-<uuid>/` on mars; they are not copied off mars (ace's `nixos/backup.nix` only covers ace). Schema and migrations are the app's job: load `db/schema.sql` once, then use a **Pre-deployment command** or the workflow to migrate.

`staging.animal-search.apps…` is two labels under `apps`, so neither the `*.apps` Caddy site nor its wildcard certificate covers it; the on-demand catch-all serves it instead (DNS is still covered, because DNS wildcards match any depth).

Both expose port 4321 (no port mappings). Coolify cannot read the Dockerfile of a Docker Image app, so `custom_healthcheck_found` was set by hand (with the Dockerfile's 10 s interval, 3 s timeout, 10 s start period, 5 retries): Coolify then waits on the image's own `HEALTHCHECK` (a `node -e fetch(...)` probe). Its built-in HTTP check would run `curl`/`wget`, which `node:22-slim` does not have. The workflow's GitHub environments need `COOLIFY_URL=https://coolify.prestonhager.com`, `COOLIFY_APP_UUID` and `APP_URL` as variables, and `COOLIFY_TOKEN` as a secret. mars pulls the image with its `ghcr.io` login in `/root/.docker/config.json`. This is separate from the Podman deployment at `animal-search.prestonhager.com` ([Animal Search on ace](animal-search-ace.md)).

The steps below are the general procedure.

### 1. Give Coolify access to the repository

The repository is private, so Coolify needs credentials. Pick one:

- **GitHub App (recommended; gives push-to-deploy):** Coolify → **Sources** → **+ Add** → **GitHub App**. Name it e.g. `coolify-ace`, keep the webhook endpoint `https://coolify.prestonhager.com`, and choose **Register now**. The app can be owned by any account or organization, not only the one that owns the repository. A GitHub App is installable only on its owner's account until it is made public, though: if you register it on your own account (or another org), open GitHub → the app's settings → **Advanced** → **Make public**, then **Install** it on `NMSU-CS-CS371` and select only the group 5 repository. An org owner has to approve the install if you are not one.
- **Deploy key (no org approval needed, manual or webhook deploys):** Coolify → **Keys & Tokens** → **Private Keys** → **+ Add** → **Generate new ED25519 key**, name it `group5-deploy`. Copy the public key into the repository: GitHub → repo → Settings → **Deploy keys** → Add (read-only). Requires admin on the repository.

GitHub Actions runners are separate from this: a self-hosted runner serves only the repository or organization it is registered to, whatever owns the Coolify app. A workflow can trigger a deploy through Coolify's API (Keys & Tokens → API tokens, then `POST https://coolify.prestonhager.com/api/v1/deploy?uuid=<app uuid>` (Coolify 4.5 answers a GET with 405) with `Authorization: Bearer <token>`) or the application's deploy webhook. The API answers the LAN/tailnet and GitHub-hosted Actions runners (see [GitHub Actions access to the API](#github-actions-access-to-the-api)), so both self-hosted and GitHub-hosted runners can call it.

### 2. Create the application

1. Coolify → **Projects** → **+ Add** → name `cs371-group5`; open the `production` environment.
2. **+ New** → **Private Repository (with GitHub App)** or **Private Repository (with Deploy Key)**.
3. Select the repository and branch (`main`), then the build pack:
   - **Dockerfile** if the repo has one at the root (or set *Base Directory* / *Dockerfile Location*),
   - **Docker Compose** for a `docker-compose.yml` with several services,
   - **Nixpacks** to auto-detect Node/Python/etc. without a Dockerfile,
   - **Docker Image** to run an image a CI workflow already pushed (e.g. to GHCR).
4. **Server**: `mars`, destination: the default `coolify` network.
5. **Ports Exposes**: the port the app listens on inside the container (e.g. `3000`).
6. **Domains**: `http://group5.apps.prestonhager.com`

   Use `http://`, not `https://`. TLS is handled by Caddy on ace; Coolify's proxy on mars has no :443 and requesting a certificate there would fail. The public URL is still `https://group5.apps.prestonhager.com`.
7. **Environment Variables**: add secrets here (stored encrypted in Coolify's database). Mark build-time variables *Build Variable* if the build needs them.
8. **Health Check** (Advanced): set a path such as `/` or `/health` so Coolify only switches traffic to a healthy new container.
9. **Deploy**. Watch the build log; the first build pulls base images on mars.

Databases the app needs (Postgres, Redis, …) can be added in the same environment with **+ New** → **Database** on `mars`; reference them from the app by the internal hostname Coolify shows.

### 3. Automatic deploys

- With the GitHub App, enable **Auto Deploy** on the application; pushes to `main` deploy automatically.
- With a deploy key, copy the application's **Webhook** URL (Webhooks tab) into GitHub → repo → Settings → Webhooks (content type `application/json`, the secret Coolify shows), or deploy manually.
- From GitHub Actions, call the deploy API above as the last job step.
- **Preview deployments** (optional): set the preview URL template to `{{pr_id}}-group5.apps.prestonhager.com`. Keep it one label under `apps`: the wildcard certificate covers `*.apps.prestonhager.com` only, not `pr-1.group5.apps…`.

### 4. Monitoring

Add the app's public URL to `coolifyAppTargets` in `nixos/monitoring/prometheus-config.nix` and rebuild ace:

```nix
coolifyAppTargets = [
  "https://group5.apps.prestonhager.com/"
];
```

It then appears in the **Coolify** Grafana dashboard (*Deployed apps*), and the *Ace service probe failed* alert pages if it is down for 5 minutes.

## Monitoring and alerts

| What | Where |
|---|---|
| Dashboard health (`/api/health` through Caddy) | essential blackbox probe; Grafana **Coolify** dashboard |
| Containers (`podman-coolify`, `-db`, `-redis`) | alert *Coolify container down* (5 min) |
| App proxy on mars:80 | essential TCP probe (`blackbox-tcp-lan-hosts`, `service="coolify-proxy"`); Coolify and Network Topology dashboards |
| Deployed apps | `coolifyAppTargets` (see above) |

## Operations

**Upgrade Coolify:** check `https://cdn.coollabs.io/coolify/versions.json`, get the manifest-list digest (`nix run nixpkgs#skopeo -- inspect --raw docker://ghcr.io/coollabsio/coolify:<version> | sha256sum`), put it in `coolifyImage` in `coolify.nix`, rebuild. Read the release notes first; upgrades are rehearsed on a restored `pg_dump` in an isolated Podman network. Since 4.6 the image layers are zstd (pulling needs Docker 23+, mars runs 29.x), and the helper image Coolify pulls on mars is `<REGISTRY_URL>/coollabsio/coolify-helper` (`ghcr.io` here, from `REGISTRY_URL` in `coolify-env`; ghcr and Docker Hub carry the same digest). Reverb only answers `/app/` on the dashboard domain, which is all Caddy routes. Do not use Coolify's built-in self-update; it expects Docker and upstream's compose layout.

**Logs:** `podman logs coolify`, `journalctl -u coolify-keycloak-roles -u coolify-keycloak-oauth`, `journalctl -u coolify-email-settings`, `journalctl -u coolify-edge-ask -u coolify-edge-nat -u coolify-edge-routes -u coolify-edge-dns`; proxy on mars: `docker logs coolify-proxy`.

**Back up:** `/stor/coolify/postgres` (Coolify's database) and `APP_KEY` in `coolify-env`. APP_KEY encrypts stored server keys, SMTP settings and environment variables; without it a database restore cannot decrypt them.

**Servers:** Coolify lists `localhost` (id 0, force-disabled by `coolify-instance-settings`; Coolify needs it to exist) and `mars` (id 2). crux (id 1) was deleted on 2026-10-20 together with its proxy containers and `/data/coolify` on crux.

**Why mars was registered by hand:** Coolify's server validation only accepts its list of distributions and rejects `ID=nixos`. Connection, Docker, Compose and `git`/`curl`/`jq` were validated; the server was then marked usable directly. Docker on mars is managed by NixOS (`virtualisation.docker`, with `liveRestore`), so Coolify's own Docker installer is never needed. 

### Adding a deploy server

For example sally:

1. Enable `homelab.coolifyNode` (`nixos/coolify-node.nix`) and `virtualisation.docker` on it, as hosts/mars does. Its `coolify-ingress` chain already lets ace reach :80.
2. Register it in Coolify (Servers → Add, root over SSH with Coolify's key) and mark it usable the same way as mars. Set its **Wildcard Domain** to `http://apps.prestonhager.com` if new apps there should default to `*.apps` names, and make sure its proxy trusts `X-Forwarded-*` from ace like mars's.
3. Add its LAN IP (the IP Coolify has for it) to `nodes` in `nixos/containers/coolify-edge.nix` and rebuild ace.

After that nothing per app is needed: pick the server when creating the app, set an `http://<name>.apps.prestonhager.com` (or other) domain, and deploy. `coolify-edge-routes` sends the name to that node, `coolify-edge-nat` forwards its published ports to it, and DNS stays pointed at ace.
