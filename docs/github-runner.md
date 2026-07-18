# GitHub Actions self-hosted runners

Reusable NixOS module: `nixos/services/github-runner.nix`  
Option namespace: `homelab.github-runners`

Enabled on **ace** (`hosts/ace/default.nix`) with **container backend** (Ubuntu Noble OCI via Podman) and **4 parallel runners**, all registered to **soundbytes-app**:

| Runner name(s) | Register URL | systemd / Podman unit(s) | Custom label |
|----------------|--------------|--------------------------|--------------|
| `ace-1` … `ace-4` | `https://github.com/PrestonHager/soundbytes-app` | `podman-github-runner-ace-1` … `-4` | `ace-ubuntu-x64-4` |

**Org / user-wide runners:** not available. `PrestonHager` is a personal GitHub user (not an Organization). `GET /orgs/PrestonHager/actions/runners` returns **404**. GitHub only supports org-scoped shared runners on Organizations. Personal accounts must register runners **per repository**. Ace therefore points all four at `soundbytes-app` (the primary CI consumer). To also serve `nixos-configs`, you would need a second set of repo-scoped runners (more CPU/RAM) or a GitHub Organization.

Token: nix-secrets `secrets/github-runner.yaml` key `token` (shared by all; rendered to `/run/github-runner/<name>.env` as `ACCESS_TOKEN=`).

Verify Online: **soundbytes-app → Settings → Actions → Runners**. On ace:

```bash
systemctl status podman-github-runner-ace-{1,2,3,4}
podman ps --filter name=github-runner
```

## Targeting workflows (`runs-on`)

Use the single custom label:

```yaml
jobs:
  build:
    runs-on: ace-ubuntu-x64-4
    steps:
      - uses: actions/checkout@v4
      # …
```

GitHub **always** also attaches read-only labels `self-hosted`, `Linux`, and `X64` (cannot be removed). Workflows may still match with `runs-on: [self-hosted, linux, x64]` style lists, but prefer **`ace-ubuntu-x64-4` alone** so jobs land only on these Ace Ubuntu 4-vCPU runners.

**Migration:** older Ace labels (`ace`, `soundbytes-app`, `ubuntu-noble`, `nixos`, …) are no longer registered. Update any workflow still using those custom labels to `ace-ubuntu-x64-4`.

## Capacity / sizing (ace)

Live profile (2026-07-12):

| Resource | Value |
|----------|-------|
| CPU | 48 logical (2× Xeon E5-2680 v3, 12 cores/socket × 2 threads) |
| RAM | 31 GiB; ~7 GiB steady used, ~23 GiB available |
| Swap | 32 GiB file (idle at profile time) |
| Other load | Nextcloud, Pterodactyl, MediaWiki, Grafana/Loki/Alloy, Matrix, Zitadel, Caddy, Samba, Technitium, … |
| Nix caps | `max-jobs=4`, `cores=12` (do not raise for CI) |

**Chosen N = 4** (all on `soundbytes-app`):

| Budget | Amount | Rationale |
|--------|--------|-----------|
| Reserved for web/OS | ~14 GiB | Steady ~7 GiB + spike headroom |
| Per-runner memory cap | `4096m` | Rust/npm jobs; hard cap so one runaway cannot eat the host |
| Peak CI RAM | ~16 GiB | 4 × 4096m; swap available if contended |
| Per-runner CPUs | `4` | 4 × 4 = 16 of 48; ~32 left for services |

Raise `instances` only after re-checking `free -h` / `systemd-cgtop` under load. Prefer more runner *containers* over job concurrency tricks (each GitHub runner is one job).

## Hardening (ephemeral + ghosts)

Ephemeral runners exit after each job and re-register. Past failure mode: process exits mid-job, local `.runner` is already gone, myoung34’s EXIT trap cannot call `config.sh remove`, GitHub keeps the runner **offline + busy**, and a job can sit `in_progress` with 0 steps.

Mitigations in this module:

1. **Baked image** — `github-runner-image.service` builds `localhost/homelab-github-runner:ubuntu-noble` from `nixos/services/github-runner/Containerfile` (base `myoung34/github-runner:ubuntu-noble` + apt build/cross packages). Ephemeral restarts should log `homelab-ci: apt/cross toolchain present (baked image)` instead of downloading ~74 MB of debs.
2. **Deregister order** — `DISABLE_AUTOMATIC_DEREGISTRATION=true`; homelab entrypoint deregisters with `config.sh remove` **while** `.runner` exists, else deletes the runner by name via the GitHub API.
3. **Workdir wipe** — each start clears `$RUNNER_WORKDIR` contents (bind-mounted `/var/lib/github-runner/<name>-<i>/work`).
4. **Ghost recovery** — timer `github-runner-ghost-watch.timer` (every ~5 min) cancels stuck jobs and restarts offline+busy units; ops script `scripts/github-runner-recover-ghost.sh` (also `github-runner-recover-ghost` on PATH on ace).

### Ghost recovery (manual)

From a machine with `gh` auth:

```bash
./scripts/github-runner-recover-ghost.sh ace-3
./scripts/github-runner-recover-ghost.sh all
```

On ace (uses `/run/github-runner/*.env`, does not print the token):

```bash
github-runner-recover-ghost --local ace-3
# or
systemctl start github-runner-ghost-watch.service
```

### Custom image build / storage

| Item | Value |
|------|--------|
| Containerfile | `nixos/services/github-runner/Containerfile` |
| Build unit | `github-runner-image.service` |
| Image tag | `localhost/homelab-github-runner:ubuntu-noble` (Podman local store) |
| Stamp | `/var/lib/github-runner-tools/image.stamp` (Containerfile sha256 + base image id) |
| Base option | `homelab.github-runners.containerBaseImage` |
| Image option | `homelab.github-runners.containerImage` |

Rebuild the image after Containerfile or base digest changes (automatic on next `github-runner-image.service` start / nixos-rebuild). Force:

```bash
rm -f /var/lib/github-runner-tools/image.stamp
systemctl restart github-runner-image.service
```

## Backend: container vs native

| | `backend = "container"` (ace default) | `backend = "native"` |
|--|----------------------------------------|----------------------|
| Runtime | Podman OCI (`localhost/homelab-github-runner:ubuntu-noble`, from myoung34) | NixOS `services.github-runners` |
| FHS / libs | Ubuntu glibc + apt (`build-essential`, openssl, …) baked into local image | Nix store PATH + `parityPackages` |
| Rust | Bootstrap installs rustup + `x86_64` + `aarch64-unknown-linux-gnu` into `/var/lib/github-runner-tools` | Must add toolchain yourself; cross `core`/`std` often missing |
| Zig | Host symlinks `pkgs.zig` → `/var/lib/github-runner-tools/bin/zig` (+ `/nix/store` RO mount) | Included in `parityPackages` |
| ffmpeg / ffprobe | Host symlinks `pkgs.ffmpeg` → `…/bin/ffmpeg` and `…/bin/ffprobe` (same tools volume + store mount) | Included in `parityPackages` |
| Job `container:` | Host Podman socket mounted at `/var/run/docker.sock` | Opt-in `docker.enable` (Docker) |
| Node externals | Image provides Actions node | Module ships `node20`+`node24` externals |

Workflows do **not** need a job-level `container:` for Ubuntu parity — the **runner itself** is Ubuntu. Optional job `container:` still works via the mounted Podman socket.

## Few steps to join GitHub

### 1. Create a token

**Recommended (ephemeral runners):** a fine-grained PAT with **Read and Write** on **repository** *Self-hosted runners* for each repo you register against (here: `soundbytes-app`).

- Fine-grained: [GitHub → Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens?type=beta)
- Classic PAT: `repo` scope (single-repo registration)

**Alternative (not recommended with `ephemeral = true`):** Settings → Actions → Runners → New self-hosted runner → copy the registration token (expires in ~1 hour).

### 2. Put the token in nix-secrets (sops)

In the **nixos-secrets** repo, add `secrets/github-runner.yaml` (encrypt with your usual age recipients / `.sops.yaml`):

```yaml
# secrets/github-runner.yaml (encrypt before commit — never commit plaintext)
token: ghp_REPLACE_ME_OR_github_pat_REPLACE_ME
```

Example encrypt (on a host with age keys, same pattern as Cloudflare):

```bash
export SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt
cd /path/to/nixos-secrets
# create plaintext yaml, then:
nix shell nixpkgs#sops --command sops --encrypt --in-place secrets/github-runner.yaml
git add secrets/github-runner.yaml && git commit -m "Add GitHub runner token" && git push
```

Then on the NixOS host:

```bash
cd /etc/nixos
nix flake update nix-secrets
```

Multiple runners can share one PAT (`tokenSecret` / `sopsKey` defaults), or use separate keys/files per runner.

### 3. Enable the module on a host

Ace already does this (`hosts/ace/default.nix`). Pattern:

```nix
{ config, pkgs, ... }:
{
  imports = [
    ../../nixos/services/github-runner.nix
  ];

  homelab.github-runners = {
    enable = true;
    backend = "container"; # or "native"
    containerMemory = "4096m";
    containerCpus = "4";
    runners = {
      ace = {
        url = "https://github.com/PrestonHager/soundbytes-app";
        instances = 4;
        # Single custom label; GitHub still adds self-hosted / Linux / X64
        extraLabels = [ "ace-ubuntu-x64-4" ];
      };
    };
  };
}
```

Native backend + Docker socket example:

```nix
homelab.github-runners = {
  enable = true;
  backend = "native";
  runners.ace = {
    url = "https://github.com/PrestonHager/soundbytes-app";
    user = "github-runner";
    group = "github-runner";
    docker.enable = true;
  };
};
```

### 4. Rebuild

On ace (respect memory caps — never unconstrained):

```bash
NIX_BUILD_CORES=12 nixos-rebuild switch --flake .#ace -j 4 --option max-jobs 4 --option cores 12
```

### 5. Verify

1. GitHub → **soundbytes-app** → **Settings → Actions → Runners** → four runners **Online** (`ace-1`…`ace-4`)
2. On the host:

```bash
systemctl status podman-github-runner-ace-{1,2,3,4}
podman logs --tail 30 github-runner-ace-1   # expect "Listening for Jobs"
podman exec github-runner-ace-1 bash -lc \
  'rustup show; rustup target list --installed; rustc --print target-libdir --target aarch64-unknown-linux-gnu; which zig; zig version; which ffmpeg ffprobe; ffmpeg -version | head -n1'
```

Expect installed targets including `aarch64-unknown-linux-gnu` (so `core`/`std` resolve), and `zig` / `ffmpeg` / `ffprobe` on `PATH` from `/var/lib/github-runner-tools/bin`. Cold start should **not** re-download apt cross packages when using the baked image (`homelab-ci: apt/cross toolchain present`). Rustup still bootstraps once into `/var/lib/github-runner-tools` (shared; flocked). Zig and ffmpeg are provisioned by `github-runner-tools-bin.service` on each rebuild.

## Options (summary)

| Option | Default | Notes |
|--------|---------|--------|
| `enable` | `false` | Master switch |
| `backend` | `"container"` | `"container"` or `"native"` |
| `containerImage` | `localhost/homelab-github-runner:ubuntu-noble` | Baked local image (see Hardening) |
| `containerBaseImage` | `myoung34/github-runner:ubuntu-noble` | FROM for `github-runner-image.service` |
| `containerMemory` / `containerCpus` | `4096m` / `4` | Defaults when per-runner `container.*` is null |
| `runners.<name>.url` | required | Org or repo URL |
| `runners.<name>.name` | attr key | Base name in GitHub UI |
| `runners.<name>.instances` | `1` | Parallel runners (`name-1`…`name-N`) |
| `runners.<name>.tokenSecret` | `github-runner-token` | sops secret attr |
| `runners.<name>.sopsFile` | `nix-secrets/.../github-runner.yaml` | |
| `runners.<name>.sopsKey` | `token` | YAML key |
| `runners.<name>.tokenFile` | `null` | Bypass sops (tests only) |
| `runners.<name>.ephemeral` | `true` | Prefer PAT |
| `runners.<name>.extraLabels` | `[ "ace-ubuntu-x64-4" ]` | Custom only; GH adds self-hosted/OS/arch |
| `runners.<name>.container.memory` / `.cpus` | `null` | Inherit top-level defaults |
| `runners.<name>.extraPackages` | `[]` | Native only |
| `runners.<name>.docker.enable` | `false` | Native only; needs `user` + `group` |
| `runners.<name>.container.mountDockerSocket` | `true` | Podman sock → docker.sock |
| `nodeRuntimes` | `[ "node20" "node24" ]` | Native only |
| `parityPackages` | curl, wget, jq, … | Native only |

### Tooling parity (container backend)

On first start of a **stock** base image, each Ubuntu runner would apt-install build/cross packages. Ace uses the **baked** local image so that step is skipped. Shared volume `/var/lib/github-runner-tools` still gets:

- **rustup** stable with targets `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` (binaries under the tools volume; on `PATH`)
- **zig** from nixpkgs (`pkgs.zig`), symlinked to `/var/lib/github-runner-tools/bin/zig` by `github-runner-tools-bin` (containers mount `/nix/store` read-only so the Nix-linked binary runs)
- **ffmpeg** / **ffprobe** from nixpkgs (`pkgs.ffmpeg`), same symlink pattern (`…/bin/ffmpeg`, `…/bin/ffprobe`) for media seed jobs (e.g. soundbytes-app)
- Env: `RUSTUP_HOME=/var/lib/github-runner-tools/rustup`, `CARGO_HOME=/root/.cargo`, cross-linker vars; `PATH` includes `$TOOLS/bin` then `$TOOLS/cargo/bin`

Each start also clears the runner **workdir** and per-container cargo/npm caches (not the shared toolchains).

This fixes CI errors like `can't find crate for core` / `std` for `aarch64-unknown-linux-gnu`, lets workflows skip downloading Zig when they detect it on `PATH` (or drop `setup-zig` on Ace-labeled jobs), and makes `ffmpeg` available for seed steps that previously failed with “no ffmpeg on Ace runners”.

**Not shared across jobs:** Cargo registry/git and npm caches. Each ephemeral container start wipes `/root/.cargo/{registry,git}` and `/root/.npm`. Restore them with **GitHub Actions cache** in the workflow (below) — not host bind-mounts.

### Caching (prefer `actions/cache`, not runner disk)

#### Why not shared `$HOME/.cache/…` on the runner

Self-hosted runners often share one machine (and Ace shares a tools volume across four containers). Writable caches on runner disk (`CARGO_HOME`, `target/`, `node_modules`, `npm` cache, `sccache`) can:

- Leak build artifacts between **repos**, **branches**, and **PRs** (including forks with read access to the runner)
- Survive `actions/checkout` refreshes of `$GITHUB_WORKSPACE` if placed outside the workspace — which is convenient and also the security footgun
- Bypass GitHub’s cache **scope** rules (repo + branch / base-branch)

Ace therefore does **not** mount a shared soundbytes/cache volume and does **not** point job `CARGO_HOME` at the shared tools volume. Toolchains may be shared (same trusted bootstrap); dependency/build caches must go through GitHub’s cache service.

#### How `actions/cache` works on self-hosted runners

- Storage is **GitHub’s cache backend** (HTTPS), not a folder on Ace.
- Scope: cache **key** + **version** + **branch**; default-branch caches are visible to other branches/PRs; unrelated branches do not share freely.
- Fork PRs typically get **read-only** cache access (cannot poison the base repo’s cache writes).
- Same API as GitHub-hosted runners; Ace’s Ubuntu Noble image already speaks the Actions cache protocol. Prefer `actions/cache@v4` (or newer compatible with your runner version); keep runners updated (`DISABLE_AUTO_UPDATE` is set — bump the image periodically).
- Repo cache size is capped (~10 GB); old entries are evicted.

#### Recommended: Rust (`Swatinem/rust-cache`)

[`Swatinem/rust-cache`](https://github.com/Swatinem/rust-cache) wraps `actions/cache` with sensible Cargo registry/git/`target` keys.

```yaml
- uses: actions/checkout@v4

- uses: dtolnay/rust-toolchain@stable
  # Optional if you rely on the runner’s preinstalled rustup; still fine on Ace Ubuntu.

- uses: Swatinem/rust-cache@v2
  with:
    workspaces: "backend -> target"
    # Self-hosted: toolchain lives on PATH from /var/lib/github-runner-tools/cargo/bin.
    # Avoid rust-cache wiping unrelated bins under ~/.cargo/bin if you put tools there.
    cache-bin: "false"
    # Optional: only save from the default branch
    # save-if: ${{ github.ref == 'refs/heads/main' }}
```

Manual equivalent (if you cannot use the composite):

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/registry/index/
      ~/.cargo/registry/cache/
      ~/.cargo/git/db/
      backend/target/
    key: ${{ runner.os }}-cargo-${{ hashFiles('**/Cargo.lock') }}
    restore-keys: |
      ${{ runner.os }}-cargo-
```

Key carefully: include lockfile hash; consider toolchain / target triple in the key when those change. Caching `target/` is a speed win but makes keys larger and more fragile across feature flags — `rust-cache` handles common cases.

#### Recommended: npm (`actions/setup-node` cache)

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: "20"
    cache: npm
    cache-dependency-path: frontend/package-lock.json
```

Or explicit:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.npm
    key: ${{ runner.os }}-npm-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-npm-
```

Do **not** commit `node_modules/` or `target/`; do **not** set runner-level `npm_config_cache` / `CARGO_TARGET_DIR` to a shared host path.

#### Patches for soundbytes-app setup composites

`soundbytes-app` (and composites such as `setup-rust-lambda` / `setup-node-monorepo`) are **not** in this repo. In that app repo, wire cache into the setup actions (or call sites), for example:

**`setup-rust-lambda` / Rust jobs** — after toolchain setup, before `cargo build` / `cargo lambda`:

```yaml
- uses: Swatinem/rust-cache@v2
  with:
    workspaces: "backend -> target"
    cache-bin: "false"
```

**`setup-node-monorepo` / Node jobs** — use setup-node’s cache (or add `actions/cache` on `~/.npm` keyed by the monorepo lockfile(s)).

Avoid exporting shared host paths into `GITHUB_ENV` (`CARGO_HOME=$HOME/.cache/soundbytes/...`, `npm_config_cache=...`, `SCCACHE_DIR=...`). If a composite currently `mkdir`s those dirs, remove that and rely on the cache actions above.

#### One-time host cleanup (optional)

If `/var/lib/github-runner-tools/cargo/{registry,git}` grew while `CARGO_HOME` previously pointed at the tools volume, prune once on ace (toolchains/binaries stay):

```bash
rm -rf /var/lib/github-runner-tools/cargo/registry \
       /var/lib/github-runner-tools/cargo/git
```

## Smoke-test without a production host

From the repo root (WSL/NixOS):

```bash
nix eval --impure --file scripts/eval-github-runner.nix
```

That builds a minimal NixOS system that imports the module once disabled (no secrets) and once enabled with a dummy `tokenFile`. It does **not** contact GitHub.

## Secrets checklist (nix-secrets)

- [ ] `secrets/github-runner.yaml` with key `token`
- [ ] Encrypted for the target host(s) in `.sops.yaml`
- [ ] `nix flake update nix-secrets` on the host before rebuild
- [ ] No plaintext tokens in **nixos-configs**
