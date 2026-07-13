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

On first start, each Ubuntu runner bootstraps (once, shared volume):

- `build-essential`, `pkg-config`, OpenSSL/FFI/zlib headers, cmake, git, jq, curl, …
- `gcc-aarch64-linux-gnu` / `g++-aarch64-linux-gnu` (cross linker)
- **rustup** stable with targets `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu`
- Env: `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc`

This fixes CI errors like `can't find crate for core` / `std` for `aarch64-unknown-linux-gnu`.

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
