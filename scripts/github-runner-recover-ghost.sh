#!/usr/bin/env bash
# Recover a GitHub Actions self-hosted runner stuck offline+busy (ghost registration).
#
# Typical failure: ephemeral runner exits mid-job without deregistering; GitHub
# keeps the runner offline+busy and may leave a job in_progress with 0 steps.
#
# Usage (from a machine with gh auth + SSH to the host):
#   ./scripts/github-runner-recover-ghost.sh ace-3
#   ./scripts/github-runner-recover-ghost.sh all
#
# Usage on the runner host (uses ACCESS_TOKEN from /run/github-runner/*.env):
#   ./scripts/github-runner-recover-ghost.sh --local ace-3
#   github-runner-recover-ghost --local all   # if installed via NixOS
#
# Env:
#   GITHUB_REPO   owner/repo (default: PrestonHager/soundbytes-app)
#   RUNNER_HOST   SSH target when not --local (default: root@192.168.5.5)
#   UNIT_PREFIX   systemd unit prefix (default: podman-github-runner-)
#
# Does not print tokens.
set -euo pipefail

LOCAL=0
RUNNER_ARG=""
GITHUB_REPO="${GITHUB_REPO:-PrestonHager/soundbytes-app}"
RUNNER_HOST="${RUNNER_HOST:-root@192.168.5.5}"
UNIT_PREFIX="${UNIT_PREFIX:-podman-github-runner-}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --local) LOCAL=1; shift ;;
    --repo) GITHUB_REPO="$2"; shift 2 ;;
    --host) RUNNER_HOST="$2"; shift 2 ;;
    all|ace-[0-9]|*-*) RUNNER_ARG="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$RUNNER_ARG" ]]; then
  echo "Runner name required (e.g. ace-3 or all)" >&2
  usage 1
fi

api() {
  local method="$1" path="$2"
  shift 2
  if [[ "$LOCAL" -eq 1 ]]; then
    local token="" envf
    for envf in /run/github-runner/*.env; do
      [[ -f "$envf" ]] || continue
      token="$(sed -n 's/^ACCESS_TOKEN=//p' "$envf" | tr -d '\r\n' | head -1)"
      [[ -n "$token" ]] && break
    done
    if [[ -z "$token" ]]; then
      echo "No ACCESS_TOKEN in /run/github-runner/*.env" >&2
      return 1
    fi
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com${path}" \
      "$@"
  else
    gh api -X "$method" "$path" "$@"
  fi
}

host_cmd() {
  if [[ "$LOCAL" -eq 1 ]]; then
    bash -lc "$*"
  else
    # shellcheck disable=SC2029
    ssh "$RUNNER_HOST" "$*"
  fi
}

list_targets() {
  if [[ "$RUNNER_ARG" == "all" ]]; then
    api GET "/repos/${GITHUB_REPO}/actions/runners" \
      | jq -r '.runners[]? | select(.status=="offline") | .name'
  else
    echo "$RUNNER_ARG"
  fi
}

cancel_jobs_for_runner() {
  local name="$1"
  local runs job_ids run_id
  runs="$(api GET "/repos/${GITHUB_REPO}/actions/runs?status=in_progress&per_page=30" \
    | jq -r '.workflow_runs[]?.id' || true)"
  for run_id in $runs; do
    [[ -z "$run_id" ]] && continue
    job_ids="$(api GET "/repos/${GITHUB_REPO}/actions/runs/${run_id}/jobs" \
      | jq -r --arg n "$name" '.jobs[]? | select(.runner_name==$n and .status=="in_progress") | .id' || true)"
    if [[ -n "$job_ids" ]]; then
      echo "Cancelling in-progress run ${run_id} (jobs on ${name})"
      api POST "/repos/${GITHUB_REPO}/actions/runs/${run_id}/cancel" >/dev/null || true
    fi
  done
}

restart_unit() {
  local name="$1"
  local unit="${UNIT_PREFIX}${name}.service"
  echo "Restarting ${unit} on host"
  host_cmd "systemctl restart '${unit}'"
}

echo "Repo=${GITHUB_REPO} mode=$([ "$LOCAL" -eq 1 ] && echo local || echo remote) target=${RUNNER_ARG}"

targets=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  targets+=("$line")
done < <(list_targets)

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "No matching offline runners (or name not offline). Will still restart requested unit(s)."
  if [[ "$RUNNER_ARG" != "all" ]]; then
    targets=("$RUNNER_ARG")
  fi
fi

for name in "${targets[@]}"; do
  echo "=== Recovering ${name} ==="
  # Show current GitHub status if present
  api GET "/repos/${GITHUB_REPO}/actions/runners" \
    | jq -r --arg n "$name" '.runners[]? | select(.name==$n) | "GitHub: id=\(.id) status=\(.status) busy=\(.busy)"' \
    || true
  cancel_jobs_for_runner "$name"
  restart_unit "$name"
  echo "Waiting for Listening..."
  sleep 8
  host_cmd "journalctl -u '${UNIT_PREFIX}${name}.service' --since '1 minute ago' --no-pager | grep -E 'Listening for Jobs|successfully added|Successfully replaced|homelab-ci' | tail -20" || true
done

echo "Done. Verify: gh api repos/${GITHUB_REPO}/actions/runners --jq '.runners[]|{name,status,busy}'"
