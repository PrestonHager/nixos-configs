# Ace K80 GPU stack

Separate flake: [PrestonHager/ace-k80-stack](https://github.com/PrestonHager/ace-k80-stack).

Host hardware: `hardware/dell-poweredge-730xd` (Dell PowerEdge R730xd). DNS: `ai.prestonhager.com` → ace (Technitium + Cloudflare grey CNAME).

## Hardware

| Item | Value |
|------|-------|
| GPU | Tesla K80 (dual GK210, Kepler) |
| Driver | `legacy_470` (470.256.02) — proprietary, not `nvidia-open` |
| Kernel | `linuxPackages_latest` (7.1.x on ace today) |
| CUDA | 11.4 (pinned via ace-k80-stack flake) |
| Power | ~300W TDP — verify R730xd PSU and airflow |

Commented stubs already exist in `hardware/dell-poweredge-730xd/hardware-configuration.nix`.

## Pre-enable validation

On ace, before `nixos-rebuild switch`:

```bash
git clone https://github.com/PrestonHager/ace-k80-stack /tmp/ace-k80-stack
cd /tmp/ace-k80-stack
NIXPKGS_ALLOW_UNFREE=1 nix build .#nvidia-kernel-modules-470 --print-build-logs
NIXPKGS_ALLOW_UNFREE=1 nix build .#cuda_11_4_toolkit --print-build-logs
```

After GPU is seated:

```bash
lspci | grep -i nvidia    # GK210
```

## NixOS integration (disabled until GPU ready)

1. **Flake input** — `flake.nix` → `inputs.ace-k80-stack`
2. **Host module** — uncomment block in `hosts/ace/default.nix`:

```nix
imports = [
  inputs.ace-k80-stack.nixosModules.k80-gpu
];

services.aceK80 = {
  enable = true;
  # enableOllama = true;    # dogkeeper886/ollama37 → /stor/ollama
  # enableOpenClaw = true;  # port 18789; set openclaw.package when packaged
};
```

3. **Caddy** — uncomment `./ai.nix` in `nixos/caddy/default.nix`
4. **Local hosts** — uncomment `ai.prestonhager.com` in `nixos/local-service-hosts.nix`

Deploy script (documents steps, dry-run build only):

```bash
bash scripts/ace-k80-deploy.sh
```

## Services

| Service | Endpoint | Notes |
|---------|----------|-------|
| Ollama 37 | `http://127.0.0.1:11434` | Container `dogkeeper886/ollama37`, data `/stor/ollama` |
| OpenClaw | `http://127.0.0.1:18789` | Gateway default port; loopback bind |
| Public | `https://ai.prestonhager.com` | Caddy → OpenClaw; `/ollama/*` → Ollama API |

### NVIDIA container toolkit (470)

When `enableOllama` is true, the module sets:

```nix
hardware.nvidia-container-toolkit = {
  enable = true;
  mount-nvidia-executables = false;  # 470 lacks nvidia-powerd
};
```

## Post-switch checklist

```bash
nvidia-smi
modprobe nvidia_uvm
systemctl status podman-ollama37        # if Ollama enabled
systemctl status openclaw-gateway       # if OpenClaw enabled
curl -sS http://127.0.0.1:11434/api/tags
curl -sS http://127.0.0.1:18789/health
bash scripts/ace-ollama-pull.sh gemma2:2b   # pull + smoke-test a K80 model
bash scripts/ace-openclaw-config.sh gemma2:2b
systemctl restart openclaw-gateway
curl -sS -o /dev/null -w '%{http_code}\n' https://ai.prestonhager.com/
```

OpenClaw config lives at `/stor/openclaw/.openclaw/openclaw.json` (template in
`config/openclaw/openclaw.json.template`). Set `OLLAMA_API_KEY=ollama-local` and
point the ollama provider at `http://127.0.0.1:11434` (no `/v1` suffix).

CUDA smoke test:

```bash
cd /tmp/ace-k80-stack
nix run .#cuda_11_4_toolkit -- nvcc --version
```

## Related docs

- [DNS on ace](dns-ace.md) — `ai` CNAME in Technitium zones
- [ace-k80-stack README](https://github.com/PrestonHager/ace-k80-stack/blob/main/README.md)
