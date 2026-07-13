# GitHub Actions self-hosted runners

Reusable NixOS module: `nixos/services/github-runner.nix`  
Option namespace: `homelab.github-runners`

Enabled on **ace** (`hosts/ace/default.nix`) with **container backend** (Ubuntu Noble OCI via Podman) and **4 parallel runners** (2 per repo):

| Runner name(s) | Register URL | systemd / Podman unit(s) | Extra labels |
|----------------|--------------|--------------------------|--------------|
| `ace-1`, `ace-2` | `https://github.com/PrestonHager/nixos-configs` | `podman-github-runner-ace-1`, `podman-github-runner-ace-2` | `nixos`, `linux`, `x64`, `ace`, `ubuntu-noble` |
| `soundbytes-app-1`, `soundbytes-app-2` | `https://github.com/PrestonHager/soundbytes-app` | `podman-github-runner-soundbytes-app-1`, `podman-github-runner-soundbytes-app-2` | `nixos`, `linux`, `x64`, `ace`, `soundbytes-app`, `ubuntu-noble` |

**Note:** `PrestonHager` is a personal GitHub user, not an organization. GitHub only allows org-wide runners on Organizations (`https://github.com/ORG`). Personal accounts must register one runner per repository.

Token: nix-secrets `secrets/github-runner.yaml` key `token` (shared by all; rendered to `/run/github-runner/<name>.env` as `ACCESS_TOKEN=`).

Verify Online: each repo → **Settings → Actions → Runners**. On ace:

```bash
systemctl status podman-github-runner-ace-1 podman-github-runner-ace-2 \
  podman-github-runner-soundbytes-app-1 podman-github-runner-soundbytes-app-2
podman ps --filter name=github-runner
```

## Capacity / sizing (ace)

Live profile (2026-07-12):

| Resource | Value |
|----------|-------|
| CPU | 48 logical (2× Xeon E5-2680 v3, 12 cores/socket × 2 threads) |
| RAM | 31 GiB; ~7 GiB steady used, ~23 GiB available |
| Swap | 32 GiB file (idle at profile time) |
| Other load | Nextcloud, Pterodactyl, MediaWiki, Grafana/Loki/Alloy, Matrix, Zitadel, Caddy, Samba, Technitium, … |
| Nix caps | `max-jobs=4`, `cores=12` (do not raise for CI) |

**Chosen N = 4** (2× `ace` + 2× `soundbytes-app`):

| Budget | Amount | Rationale |
|--------|--------|-----------|
| Reserved for web/OS | ~14 GiB | Steady ~7 GiB + spike headroom |
| Per-runner memory cap | `3072m` | Rust/npm jobs ~2–3 GiB typical |
| Peak CI RAM | ~12 GiB | 4 × 3072m hard cap |
| Per-runner CPUs | `8` | 4 × 8 = 32 of 48; ~16 left for services |

Raise `instances` only after re-checking `free -h` / `systemd-cgtop` under load. Prefer more runner *containers* over job concurrency tricks (each GitHub runner is one job).

## Backend: container vs native

| | `backend = "container"` (ace default) | `backend = "native"` |
|--|----------------------------------------|----------------------|
| Runtime | Podman OCI (`myoung34/github-runner:ubuntu-noble`) | NixOS `services.github-runners` |
| FHS / libs | Ubuntu glibc + apt (`build-essential`, openssl, …) | Nix store PATH + `parityPackages` |
| Rust | Bootstrap installs rustup + `x86_64` + `aarch64-unknown-linux-gnu` into `/var/lib/github-runner-tools` | Must add toolchain yourself; cross `core`/`std` often missing |
| Job `container:` | Host Podman socket mounted at `/var/run/docker.sock` | Opt-in `docker.enable` (Docker) |
| Node externals | Image provides Actions node | Module ships `node20`+`node24` externals |

Workflows do **not** need a job-level `container:` for Ubuntu parity — the **runner itself** is Ubuntu. Optional job `container:` still works via the mounted Podman socket.

## Few steps to join GitHub

### 1. Create a token

**Recommended (ephemeral runners):** a fine-grained PAT with **Read and Write** on **organization** or **repository** *Self-hosted runners*.

- Org-wide: [GitHub → Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens?type=beta)
- Classic PAT: `admin:org` (org) or `repo` (single repo)

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
    containerMemory = "3072m";
    containerCpus = "8";
    runners = {
      ace = {
        url = "https://github.com/PrestonHager/nixos-configs";
        instances = 2;
        extraLabels = [ "nixos" "linux" "x64" "ace" "ubuntu-noble" ];
      };
      soundbytes-app = {
        url = "https://github.com/PrestonHager/soundbytes-app";
        instances = 2;
        extraLabels = [ "nixos" "linux" "x64" "ace" "soundbytes-app" "ubuntu-noble" ];
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
    url = "https://github.com/PrestonHager/nixos-configs";
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

1. GitHub → repo → **Settings → Actions → Runners** → four runners **Online** (`ace-1`/`ace-2`, `soundbytes-app-1`/`soundbytes-app-2`)
2. On the host:

```bash
systemctl status podman-github-runner-ace-{1,2} podman-github-runner-soundbytes-app-{1,2}
podman exec github-runner-soundbytes-app-1 bash -lc \
  'rustup show; rustup target list --installed; rustc --print target-libdir --target aarch64-unknown-linux-gnu'
```

Expect installed targets including `aarch64-unknown-linux-gnu` (so `core`/`std` resolve). First container start bootstraps apt + rustup into `/var/lib/github-runner-tools` (shared; flocked).

## Options (summary)

| Option | Default | Notes |
|--------|---------|--------|
| `enable` | `false` | Master switch |
| `backend` | `"container"` | `"container"` or `"native"` |
| `containerImage` | `myoung34/github-runner:ubuntu-noble` | Ubuntu Noble Actions runner |
| `containerMemory` / `containerCpus` | `3072m` / `8` | Per-container caps |
| `runners.<name>.url` | required | Org or repo URL |
| `runners.<name>.name` | attr key | Base name in GitHub UI |
| `runners.<name>.instances` | `1` | Parallel runners (`name-1`…`name-N`) |
| `runners.<name>.tokenSecret` | `github-runner-token` | sops secret attr |
| `runners.<name>.sopsFile` | `nix-secrets/.../github-runner.yaml` | |
| `runners.<name>.sopsKey` | `token` | YAML key |
| `runners.<name>.tokenFile` | `null` | Bypass sops (tests only) |
| `runners.<name>.ephemeral` | `true` | Prefer PAT |
| `runners.<name>.extraLabels` | `[ "nixos" ]` | |
| `runners.<name>.extraPackages` | `[]` | Native only |
| `runners.<name>.docker.enable` | `false` | Native only; needs `user` + `group` |
| `runners.<name>.container.mountDockerSocket` | `true` | Podman sock → docker.sock |
| `nodeRuntimes` | `[ "node20" "node24" ]` | Native only |
| `parityPackages` | curl, wget, jq, … | Native only |

### Tooling parity (container backend)

On first start, each Ubuntu runner bootstraps (once, shared volume `/var/lib/github-runner-tools`):

- `build-essential`, `pkg-config`, OpenSSL/FFI/zlib headers, cmake, git, jq, curl, …
- `gcc-aarch64-linux-gnu` / `g++-aarch64-linux-gnu` (cross linker)
- **rustup** stable with targets `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` (binaries under the tools volume; on `PATH`)
- Env: `RUSTUP_HOME=/var/lib/github-runner-tools/rustup`, `CARGO_HOME=/root/.cargo`, cross-linker vars

This fixes CI errors like `can't find crate for core` / `std` for `aarch64-unknown-linux-gnu`.

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

### Workflow labels (soundbytes-app / other repos)

Existing labels (`self-hosted`, `linux`, `x64`, `ace`, `soundbytes-app`) still match. Optional: add `ubuntu-noble` to prefer these containers. No required `container:` image change for Rust cross-compile — jobs already run on Ubuntu. If a workflow forced a NixOS-hostile toolchain install, prefer relying on the preinstalled rustup or `dtolnay/rust-toolchain` (works on Ubuntu).

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
