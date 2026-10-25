"""Turn the AbuseIPDB blacklist into BIRD blackhole routes for Astracap.

Run by abuseipdb-blackhole-sync.service (see abuseipdb-blackhole.nix). Steps:

1. Fetch the blacklist (at most every 5 h: a free account gets 5 downloads a day).
   On failure, keep using the last good list while it is under 48 h old; after
   that announce nothing, since AbuseIPDB scores decay and stale entries block
   addresses that are no longer bad.
2. Keep IPv4 global unicast addresses with a score >= ABUSEIPDB_MIN_CONFIDENCE that
   are outside the allowlist (static ranges, Cloudflare, GitHub, extra entries).
3. Cap at ABUSEIPDB_MAX_PREFIXES, highest score and most recent report first.
4. Write routes.conf atomically, check the whole BIRD config, `birdc configure`.
   If BIRD rejects it, the previous file is restored.
5. Write Prometheus textfile metrics.

--bgp-state-only only refreshes the BGP session metric.
--dry-run fetches and filters, prints a summary, and changes nothing.
--from-file PATH uses a saved blacklist JSON instead of the API (testing).
"""
import ipaddress
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

STATE = os.environ.get("ABUSEIPDB_STATE_DIR", "/var/lib/abuseipdb-blackhole")
ROUTES = os.environ.get("ABUSEIPDB_ROUTES_FILE", f"{STATE}/routes.conf")
PROM = os.environ.get("ABUSEIPDB_PROM", "/var/lib/node-exporter-textfile/abuseipdb_blackhole.prom")
PROM_BGP = os.environ.get("ABUSEIPDB_PROM_BGP", "/var/lib/node-exporter-textfile/abuseipdb_blackhole_bgp.prom")
KEY_FILE = os.environ.get("ABUSEIPDB_KEY_FILE", "")
MIN_CONF = int(os.environ.get("ABUSEIPDB_MIN_CONFIDENCE", "95"))
MAX_PREFIXES = int(os.environ.get("ABUSEIPDB_MAX_PREFIXES", "10000"))
EXTRA_ALLOW = os.environ.get("ABUSEIPDB_ALLOWLIST", "").split()
ROUTER_EXPECTED = os.environ.get("ABUSEIPDB_ROUTER_EXPECTED", "0")
BIRD_CONF = os.environ.get("ABUSEIPDB_BIRD_CONF", "/etc/bird/bird.conf")

CACHE = f"{STATE}/blacklist.json"
ALLOW_CACHE = f"{STATE}/allow-ranges.json"
MIN_FETCH_INTERVAL = 5 * 3600
MAX_LIST_AGE = 48 * 3600

# Never blackhole these, whatever the list says. Private, CGNAT (tailnet), loopback,
# link-local and multicast are already rejected by is_global; listed for clarity.
STATIC_ALLOW = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    "98.249.78.62/32",                    # ip1.lc1.nm.us.prestonhager.com, our WAN
    "1.1.1.1/32", "1.0.0.1/32",           # Cloudflare DNS (DHCP fallback resolver)
    "8.8.8.8/32", "8.8.4.4/32",           # Google DNS (Caddy tls_resolvers)
    "9.9.9.9/32", "149.112.112.112/32",   # Quad9
]


def log(msg):
    print(f"abuseipdb-blackhole: {msg}", file=sys.stderr, flush=True)


def get(url, headers=None, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "ace-abuseipdb-blackhole", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def atomic_write(path, data, mode=0o644, group=None):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        f.write(data)
    os.chmod(tmp, mode)
    if group is not None:
        try:
            shutil.chown(tmp, group=group)
        except (LookupError, PermissionError):
            pass
    os.replace(tmp, path)


def fetch_allow_ranges():
    """Cloudflare and GitHub ranges, refreshed with each blacklist download."""
    nets = []
    try:
        nets += get("https://www.cloudflare.com/ips-v4", timeout=30).decode().split()
        meta = json.loads(get("https://api.github.com/meta", timeout=30))
        for k in ("hooks", "web", "api", "git", "packages", "pages", "importer", "actions", "dependabot", "copilot"):
            nets += [n for n in meta.get(k, []) if ":" not in n]
        if len(nets) < 50:
            raise ValueError(f"only {len(nets)} ranges")
        atomic_write(ALLOW_CACHE, json.dumps(nets))
    except Exception as e:  # keep the last good copy
        log(f"allow-range refresh failed ({e}); using cached ranges")
        try:
            nets = json.load(open(ALLOW_CACHE))
        except Exception:
            nets = []
    return nets


def load_cache():
    try:
        return json.load(open(CACHE))
    except Exception:
        return None


def fetch_blacklist(key, force):
    cache = load_cache()
    if cache and not force and time.time() - cache.get("fetched_at", 0) < MIN_FETCH_INTERVAL:
        return cache, "cached"
    url = (f"https://api.abuseipdb.com/api/v2/blacklist?confidenceMinimum={MIN_CONF}"
           f"&limit={MAX_PREFIXES * 2}&ipVersion=4")
    try:
        body = json.loads(get(url, headers={"Key": key, "Accept": "application/json"}))
        data = body.get("data")
        if not isinstance(data, list) or not data:
            raise ValueError(f"no data in response: {str(body)[:200]}")
        cache = {"fetched_at": time.time(), "generated_at": body.get("meta", {}).get("generatedAt"), "data": data}
        atomic_write(CACHE, json.dumps(cache), mode=0o640)
        return cache, "fetched"
    except Exception as e:
        log(f"blacklist download failed: {e}")
        if cache and time.time() - cache.get("fetched_at", 0) < MAX_LIST_AGE:
            return cache, "stale-cache"
        return None, "failed"


def select(entries, allow):
    allow_nets = []
    for n in STATIC_ALLOW + allow + EXTRA_ALLOW:
        try:
            allow_nets.append(ipaddress.ip_network(n, strict=False))
        except ValueError:
            log(f"ignoring bad allowlist entry {n!r}")
    picked, skipped = [], {"low_score": 0, "not_global": 0, "allowlisted": 0, "invalid": 0}
    for e in entries:
        try:
            ip = ipaddress.ip_address(e["ipAddress"])
        except (KeyError, ValueError):
            skipped["invalid"] += 1
            continue
        if ip.version != 4 or not ip.is_global:
            skipped["not_global"] += 1
            continue
        if int(e.get("abuseConfidenceScore", 0)) < MIN_CONF:
            skipped["low_score"] += 1
            continue
        if any(ip in n for n in allow_nets):
            skipped["allowlisted"] += 1
            continue
        picked.append(e)
    picked.sort(key=lambda e: (int(e.get("abuseConfidenceScore", 0)), e.get("lastReportedAt", "")), reverse=True)
    capped = len(picked) > MAX_PREFIXES
    return [e["ipAddress"] for e in picked[:MAX_PREFIXES]], skipped, capped


def apply_routes(ips):
    text = "".join(f"route {ip}/32 blackhole;\n" for ip in sorted(set(ips), key=ipaddress.ip_address))
    old = open(ROUTES).read() if os.path.exists(ROUTES) else ""
    if text == old:
        return "unchanged"
    atomic_write(ROUTES, text, mode=0o640, group="bird")
    check = subprocess.run(["bird", "-p", "-c", BIRD_CONF], capture_output=True, text=True)
    reconf = None
    if check.returncode == 0:
        reconf = subprocess.run(["birdc", "configure"], capture_output=True, text=True)
    if check.returncode != 0 or reconf.returncode != 0 or "error" in (reconf.stdout + reconf.stderr).lower():
        atomic_write(ROUTES, old, mode=0o640, group="bird")
        out = (check.stdout + check.stderr) if check.returncode else (reconf.stdout + reconf.stderr)
        raise RuntimeError(f"BIRD rejected the new routes, previous list restored: {out.strip()[:300]}")
    return "applied"


def bgp_established():
    try:
        out = subprocess.run(["birdc", "show", "protocols", "astracap"], capture_output=True, text=True, timeout=10).stdout
        return 1 if "Established" in out else 0
    except Exception:
        return 0


def write_bgp_metric():
    up = bgp_established()
    atomic_write(PROM_BGP, (
        "# HELP homelab_abuseipdb_bgp_established 1 when BIRD's BGP session to Astracap is Established.\n"
        "# TYPE homelab_abuseipdb_bgp_established gauge\n"
        f'homelab_abuseipdb_bgp_established{{router_expected="{ROUTER_EXPECTED}"}} {up}\n'))


def write_metrics(configured, status, announced, generated_at, skipped, capped):
    lines = [
        "# HELP homelab_abuseipdb_configured 1 when an AbuseIPDB API key is configured.",
        "# TYPE homelab_abuseipdb_configured gauge",
        f"homelab_abuseipdb_configured {int(configured)}",
        "# HELP homelab_abuseipdb_sync_success 1 when the last sync applied a fresh or usable list.",
        "# TYPE homelab_abuseipdb_sync_success gauge",
        f'homelab_abuseipdb_sync_success{{status="{status}"}} {int(status in ("fetched", "cached", "stale-cache"))}',
        "# HELP homelab_abuseipdb_announced Addresses announced to Astracap as blackhole routes.",
        "# TYPE homelab_abuseipdb_announced gauge",
        f"homelab_abuseipdb_announced {announced}",
        "# HELP homelab_abuseipdb_capped 1 when more addresses qualified than maxPrefixes allows.",
        "# TYPE homelab_abuseipdb_capped gauge",
        f"homelab_abuseipdb_capped {int(capped)}",
        "# HELP homelab_abuseipdb_skipped Blacklist entries not announced, by reason.",
        "# TYPE homelab_abuseipdb_skipped gauge",
    ] + [f'homelab_abuseipdb_skipped{{reason="{k}"}} {v}' for k, v in sorted(skipped.items())] + [
        "# HELP homelab_abuseipdb_last_run_timestamp_seconds When the sync last ran.",
        "# TYPE homelab_abuseipdb_last_run_timestamp_seconds gauge",
        f"homelab_abuseipdb_last_run_timestamp_seconds {int(time.time())}",
    ]
    if generated_at:
        try:
            ts = time.mktime(time.strptime(generated_at[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
            lines += ["# HELP homelab_abuseipdb_list_generated_timestamp_seconds When AbuseIPDB generated the list in use.",
                      "# TYPE homelab_abuseipdb_list_generated_timestamp_seconds gauge",
                      f"homelab_abuseipdb_list_generated_timestamp_seconds {int(ts)}"]
        except ValueError:
            pass
    atomic_write(PROM, "\n".join(lines) + "\n")


def main():
    args = sys.argv[1:]
    if "--bgp-state-only" in args:
        write_bgp_metric()
        return 0
    dry = "--dry-run" in args
    os.makedirs(STATE, exist_ok=True)

    if "--from-file" in args:
        body = json.load(open(args[args.index("--from-file") + 1]))
        cache, status = {"data": body.get("data", []), "generated_at": body.get("meta", {}).get("generatedAt")}, "fetched"
        configured = True
    else:
        key = open(KEY_FILE).read().strip() if KEY_FILE and os.path.exists(KEY_FILE) else ""
        configured = bool(key)
        if not configured:
            log("no AbuseIPDB API key configured; announcing nothing")
            if not dry:
                apply_routes([])
                write_metrics(False, "unconfigured", 0, None, {}, False)
                write_bgp_metric()
            return 0
        cache, status = fetch_blacklist(key, force="--force" in args)

    if cache is None:
        log("no usable list (download failed and no recent copy); withdrawing all routes")
        ips, skipped, capped = [], {}, False
    else:
        ips, skipped, capped = select(cache["data"], fetch_allow_ranges())
    log(f"list {status}: {len(cache['data']) if cache else 0} entries, {len(ips)} to announce, "
        f"skipped {skipped}{', capped at ' + str(MAX_PREFIXES) if capped else ''}")
    if dry:
        print("\n".join(ips[:20]) + ("\n..." if len(ips) > 20 else ""))
        return 0
    try:
        result = apply_routes(ips)
        log(f"routes {result} ({len(ips)} announced)")
    except RuntimeError as e:
        log(str(e))
        status = "bird-rejected"
    # What BIRD actually announces: after a rejection that is the restored old list.
    announced = sum(1 for line in open(ROUTES) if line.startswith("route ")) if os.path.exists(ROUTES) else 0
    write_metrics(configured, status, announced,
                  cache.get("generated_at") if cache else None, skipped, capped)
    write_bgp_metric()
    return 0 if status in ("fetched", "cached", "stale-cache") else 1


if __name__ == "__main__":
    sys.exit(main())
