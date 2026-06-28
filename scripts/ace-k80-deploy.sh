#!/usr/bin/env bash
# Deploy Ace K80 GPU stack after hardware install + driver verification.
# Does NOT run nixos-rebuild switch — review and execute steps manually on ace.
#
# Usage (on ace, after pulling nixos-configs):
#   bash scripts/ace-k80-deploy.sh
set -euo pipefail

REPO="${REPO:-/etc/nixos}"
STACK_REPO="${STACK_REPO:-https://github.com/PrestonHager/ace-k80-stack}"

cat <<'EOF'
=== Ace K80 GPU deploy checklist ===

Prerequisites (hardware):
  1. K80 installed in R730xd (power + airflow — 300W TDP)
  2. lspci | grep -i nvidia  → GK210 visible

Pre-switch validation (read-only builds):
  3. Clone ace-k80-stack and build driver modules:
       git clone STACK_REPO /tmp/ace-k80-stack
       cd /tmp/ace-k80-stack
       NIXPKGS_ALLOW_UNFREE=1 nix build .#nvidia-kernel-modules-470 --print-build-logs
       NIXPKGS_ALLOW_UNFREE=1 nix build .#cuda_11_4_toolkit --print-build-logs
  4. nixos-rebuild build --flake REPO#ace   (must succeed before switch)

Enable in nixos-configs (uncomment on ace branch):
  5. flake.nix — ace-k80-stack input (already added)
  6. hosts/ace/default.nix — imports + services.aceK80.enable = true
  7. Optional: services.aceK80.enableOllama / enableOpenClaw
  8. nixos/caddy/default.nix — uncomment ./ai.nix import
  9. nixos/local-service-hosts.nix — uncomment ai.prestonhager.com

Deploy:
 10. cd REPO && git pull --ff-only
 11. nix flake update ace-k80-stack
 12. nixos-rebuild switch --flake .#ace

Post-switch verification:
 13. nvidia-smi                          → K80 listed
 14. modprobe nvidia_uvm && lsmod | grep nvidia
 15. systemctl status podman-ollama37     (if enableOllama)
 16. systemctl status openclaw-gateway   (if enableOpenClaw + package set)
 17. curl -sS http://127.0.0.1:11434/api/tags   (Ollama)
 18. curl -sS http://127.0.0.1:18789/health     (OpenClaw, if running)
 19. curl -sS -o /dev/null -w '%{http_code}\n' https://ai.prestonhager.com/

See docs/ace-k80-gpu.md for full reference.

EOF

echo "Repo path: $REPO"
echo "Stack flake: $STACK_REPO"
echo ""
echo "=== Dry-run: nixos-rebuild build (no switch) ==="
if [ -d "$REPO" ]; then
  cd "$REPO"
  nixos-rebuild build --flake ".#ace" 2>&1 | tail -20 || {
    echo "Build failed — enable services.aceK80 in hosts/ace/default.nix first." >&2
    exit 1
  }
else
  echo "Skip: $REPO not found (run on ace after /etc/nixos is synced)"
fi
