# GitHub Actions self-hosted runners

Reusable NixOS module: `nixos/services/github-runner.nix`  
Option namespace: `homelab.github-runners`

Enabled on **ace** (`hosts/ace/default.nix`) with two runners:

| Runner name | Register URL | systemd unit | Extra labels |
|-------------|--------------|--------------|--------------|
| `ace` | `https://github.com/PrestonHager` (org-wide) | `github-runner-ace` | `nixos`, `linux`, `x64`, `ace` |
| `soundbytes-app` | `https://github.com/PrestonHager/soundbytes-app` | `github-runner-soundbytes-app` | `nixos`, `linux`, `x64`, `ace`, `soundbytes-app` |

Token: nix-secrets `secrets/github-runner.yaml` key `token` (shared by both).

Verify Online: org → **Settings → Actions → Runners**, and repo → **Settings → Actions → Runners**. On ace: `systemctl status github-runner-ace github-runner-soundbytes-app`.

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

Ace already does this (`hosts/ace/default.nix`). Pattern for another host:

```nix
{ config, pkgs, ... }:
{
  imports = [
    ../../nixos/services/github-runner.nix
  ];

  homelab.github-runners = {
    enable = true;
    runners = {
      # Org-wide (any repo in the org can use it):
      ace = {
        url = "https://github.com/PrestonHager";
        extraLabels = [ "nixos" "linux" "x64" "ace" ];
      };
      # Single repo:
      soundbytes-app = {
        url = "https://github.com/PrestonHager/soundbytes-app";
        extraLabels = [ "nixos" "linux" "x64" "ace" "soundbytes-app" ];
      };
    };
  };
}
```

Optional Docker for `container:` jobs:

```nix
homelab.github-runners.runners.ace = {
  url = "https://github.com/PrestonHager";
  user = "github-runner";
  group = "github-runner";
  docker.enable = true;
};
```

### 4. Rebuild

```bash
sudo nixos-rebuild switch --flake /etc/nixos#HOSTNAME
```

### 5. Verify

1. GitHub → org or repo → **Settings → Actions → Runners** → runner **Online**
2. On the host (ace):

```bash
systemctl status github-runner-ace github-runner-soundbytes-app
journalctl -u github-runner-ace -u github-runner-soundbytes-app -e
```

## Options (summary)

| Option | Default | Notes |
|--------|---------|--------|
| `enable` | `false` | Master switch |
| `runners.<name>.url` | required | Org or repo URL |
| `runners.<name>.name` | attr key | Name in GitHub UI |
| `runners.<name>.tokenSecret` | `github-runner-token` | sops secret attr |
| `runners.<name>.sopsFile` | `nix-secrets/.../github-runner.yaml` | |
| `runners.<name>.sopsKey` | `token` | YAML key |
| `runners.<name>.tokenFile` | `null` | Bypass sops (tests only) |
| `runners.<name>.ephemeral` | `true` | Prefer PAT |
| `runners.<name>.extraLabels` | `[ "nixos" ]` | |
| `runners.<name>.extraPackages` | `[]` | git/nix already on PATH |
| `runners.<name>.docker.enable` | `false` | Needs `user` + `group` |

Under the hood this configures NixOS `services.github-runners`.

## Smoke-test without a production host

From the repo root (WSL/NixOS):

```bash
nix eval --impure --file scripts/eval-github-runner.nix
# → { disabled = false; enabled = true; ephemeral = true; labels = [ "nixos" ]; ... }
```

That builds a minimal NixOS system that imports the module once disabled (no secrets) and once enabled with a dummy `tokenFile`. It does **not** contact GitHub.

## Secrets checklist (nix-secrets)

- [ ] `secrets/github-runner.yaml` with key `token`
- [ ] Encrypted for the target host(s) in `.sops.yaml`
- [ ] `nix flake update nix-secrets` on the host before rebuild
- [ ] No plaintext tokens in **nixos-configs**
