# Ace rebuild freeze — root cause analysis (2026-07-12)

Read-only investigation after multiple freezes of **ace** (Dell PowerEdge R730xd, `192.168.5.5`) during NixOS rebuilds related to GitHub runner `node20` / parity packages (`68a5421` and follow-ups). Recovery: iDRAC ForceRestart — see [ace-idrac.md](ace-idrac.md) (`192.168.5.10`).

## Most likely root cause

**Unconstrained Nix parallelism on a 31 GiB host with no swap, while compiling memory-heavy packages (`nodejs_20` / `nodejs-slim-20`) and overlapping rebuilds**, drove the machine into severe memory pressure / reclaim thrashing. Userspace (including `sshd`) stopped making progress while the kernel network stack stayed up.

This is memory-exhaustion thrashing, not a confirmed classic kernel OOM kill (no `Out of memory` / `oom-kill` lines were found in surviving journals).

## Evidence

### Host capacity vs Nix defaults (live, post-reboot)

| Setting | Observed on ace |
|---------|-----------------|
| RAM | **31 GiB** (`free -h`) |
| Swap / zram | **none** (`swapon` empty; `swapDevices = [ ]` in hardware-configuration) |
| CPUs | **48** (2× Xeon E5-2680 v3) |
| `nix.settings` / `/etc/nix/nix.conf` | `max-jobs = auto` → **48**, `cores = 0` (unlimited threads per job) |
| Idle service footprint | ~5 GiB used with clamav, grafana, technitium, jellyfin, openclaw, loki, zitadel, suricata, synapse, etc. |

A single `nodejs` source build with high `-j` routinely wants many GB; with `cores = 0` on 48 CPUs it can spawn dozens of `cc` processes. That alone can exceed 31 GiB once production services and a second rebuild share the box.

### Freeze symptoms (both incidents)

- ICMP ping OK; TCP/22 accepts connections.
- SSH **never sends a banner** (userspace hung / not scheduled).
- Required **iDRAC ForceRestart** (GracefulRestart not usable when hung).

Matches “kernel alive, userspace dead” under extreme reclaim with **no swap** to absorb spikes.

### Timeline correlation (agent + surviving journals)

1. **~13:00–14:00 MDT** — Probe `nix build` of `github-runner` with `nodeRuntimes` including `node20` on the live host; SSH banner hang. Journals from that boot were **lost** after hard reset (`journalctl --list-boots` only retains later boots).
2. **After user reboot** — Constrained `nixos-rebuild … -j 2` attempts, plus eval/permit fixes for insecure packages.
3. **Second hang** — Agent observed **two overlapping** `nixos-rebuild` processes (one unconstrained without `max-jobs`); aborted mid-cleanup. Host hung again; iDRAC ForceRestart.
4. **Surviving previous boot** (`-b -1`, ~16:15–16:21 MDT, ~6 minutes):
   - **119×** `kernel: audit: kauditd hold queue overflow` (audit backlog under load).
   - Giant `audit: EXECVE` floods under `/home/prestonh/Projects/panel/node_modules/…` (CI / filesystem audit storm concurrent with runner churn).
   - `github-runner-soundbytes-app` restart loop (counter ≥5–6).
   - Hard cut at 16:21:48 (ForceRestart) — no clean shutdown.
   - **0** matches for `Out of memory` / `oom-kill` / `Killed process` in journals since 2026-07-12 00:00.
5. Store still has unfinished `.drv` / lock artifacts for `nodejs-slim-20.20.2` and `github-runner` — build interrupted, not cleanly finished.

### Why SSH banner hang specifically

`sshd` needs userspace scheduling and memory to accept and write the protocol banner. Under thrashing:

- Kernel softirq / TCP still ACKs SYN → port 22 “open”.
- `sshd` child / PAM path stalls → client hangs before banner.
- Ping works because it is kernel ICMP.

## Contributing factors

| Factor | Role |
|--------|------|
| **HW:** 31 GiB on a 48-thread box | CPU parallelism ≫ RAM headroom |
| **HW/SW:** No swap/zram | Spikes become hard thrashing instead of soft reclaim |
| **SW:** `max-jobs = auto`, `cores = 0` | Default Nix will use the whole machine |
| **SW:** Building `nodejs_20` + runner on the **production** host | Heaviest packages in the dependency graph for `68a5421` |
| **SW:** Overlapping rebuild sessions | Doubles peak RAM/IO |
| **SW:** Live services + Suricata audit | Baseline RAM + audit flood (`kauditd` overflow) under stress |
| **Ops:** Agents/CI probing builds on ace | Same host as Matrix/Nextcloud/DNS/runners |

## Three corrective actions

### 1. Software — permanently cap Nix on ace (highest leverage)

In `hosts/ace` (or a small imported module), set e.g.:

```nix
nix.settings = {
  max-jobs = 2;
  cores = 2;
};
```

Always rebuild with:

```bash
NIX_BUILD_CORES=2 nixos-rebuild switch --flake .#ace -j 2 --option max-jobs 2 --option cores 2
```

Never start a second rebuild while one is running. Prefer substituters; avoid local source builds of Node when cache hits exist.

### 2. Hardware / kernel safety net — add swap and/or zram; consider more RAM

- **Configured (pending apply):** 32 GiB disk swap file at `/var/lib/swapfile` on root (`hosts/ace/default.nix` → `swapDevices`). Root has ~2.9 T free; file is created on activation when `size` is set. **Not yet live** — wait for a careful constrained rebuild (see below); do not `nixos-rebuild` unconstrained just to enable swap.
- **zram considered, disk swap chosen:** zram would compress pages in RAM and compete with the already-tight 31 GiB working set under a heavy `nodejs` build. A disk-backed swap file on the large root volume absorbs spikes without shrinking usable RAM.
- Longer term: populate empty R730xd DIMM slots toward **64 GiB+** if ace remains both builder and production host.

**Safe apply (swap-enabling rebuild):** prefer implementing option 1 (`nix.settings.max-jobs` / `cores` caps) in the **same** rebuild (or first), then:

```bash
NIX_BUILD_CORES=2 nixos-rebuild switch --flake .#ace -j 2 --option max-jobs 2 --option cores 2
```

### 3. Software / architecture — keep heavy builds off the live production host

- Prefer **binary caches** / prebuilt `github-runner` with `node20` from a machine that is not ace, or a dedicated remote builder.
- Do not run unconstrained `nix build` probes of `nodejs`/`github-runner` on ace.
- When deploying runner changes, serialize: stop overlapping agent rebuilds; optionally pause non-critical CI runners during the switch.

## What NOT to do on ace going forward

- Do **not** run unconstrained `nixos-rebuild` / `nix build` (default `max-jobs=auto` / `cores=0`).
- Do **not** overlap two rebuilds or a rebuild plus a heavy local `nix build`.
- Do **not** probe-build `nodejs_20` / `github-runner` on the live host “to see if it works”.
- Do **not** assume TCP/22 open means the host is healthy — wait for an SSH **banner** / interactive shell.
- If hung again: use **iDRAC** `192.168.5.10` ForceRestart ([ace-idrac.md](ace-idrac.md)); do not pile on more SSH rebuild attempts.

## Status — option 2 (swap)

| Item | State |
|------|--------|
| Config | `swapDevices` → `/var/lib/swapfile`, 32 GiB in `hosts/ace/default.nix` |
| Live on ace | **No** — config only; constrained rebuild not run yet |
| Next | Apply with capped `-j` / `max-jobs` (option 1 recommended in same switch); confirm with `swapon --show` |

## Related

- Commit that introduced the heavy dependency: `68a5421` (runner `nodeRuntimes` + parity packages including `nodejs_20`).
- Recovery: [ace-idrac.md](ace-idrac.md)
- Runners: [github-runner.md](github-runner.md)
