#!/usr/bin/env python3
"""Route traffic that ace does not serve itself to the apps in Coolify.

Two jobs, both driven by what is configured in Coolify's database
(read with `podman exec coolify-db psql`, so no API token is needed):

  serve  Answers Caddy's on-demand TLS "ask" (GET /ask?domain=<host>) with
         200 only for hostnames that a Coolify application, preview or
         service uses. Caddy's catch-all site (nixos/caddy/coolify.nix) then
         gets a certificate and proxies the request to Coolify's proxy on the
         deploy server. Anything else is refused, so random SNI names never
         reach Let's Encrypt.

  nat    Reconciles Astracap's static NAT with Coolify: every host port an
         application or database on a managed deploy server publishes
         (ports_mappings, or "Make it publicly available" on a database) gets
         `ip nat inside source static <proto> <node> <port> interface <wan> <port>`,
         and lines for a managed node that Coolify no longer wants are removed.
         Lines for other inside addresses (ace :80/:443, Pterodactyl game
         ports) are never touched. The router is only contacted when the
         wanted set changed or the last check is older than --recheck, so a
         router reboot (rules are running-config only) heals within that time.

Configuration comes from the environment (set by nixos/containers/coolify-edge.nix).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PODMAN = os.environ.get("PODMAN", "podman")
SSH = os.environ.get("SSH", "ssh")
MANAGED_NODES = set(os.environ.get("COOLIFY_EDGE_NODES", "").split())
ZONES = [z.lower().strip(".") for z in os.environ.get("COOLIFY_EDGE_ZONES", "").split()]
BLOCKED_PORTS = {int(p) for p in os.environ.get("COOLIFY_EDGE_BLOCKED_PORTS", "").split()}
WAN_INTERFACE = os.environ.get("COOLIFY_EDGE_WAN_INTERFACE", "GigabitEthernet0/0")
ROUTER_SSH_CONFIG = os.environ.get("COOLIFY_EDGE_ROUTER_SSH_CONFIG", "")
ROUTER_HOST = os.environ.get("COOLIFY_EDGE_ROUTER_HOST", "astracap")
STATE_FILE = os.environ.get("COOLIFY_EDGE_STATE", "/var/lib/coolify-edge/nat.json")
MAX_RANGE = 100

DOMAIN_SQL = r"""
select fqdn from applications where deleted_at is null and coalesce(fqdn, '') <> ''
union all select docker_compose_domains from applications
  where deleted_at is null and coalesce(docker_compose_domains, '') <> ''
union all select fqdn from application_previews where deleted_at is null and coalesce(fqdn, '') <> ''
union all select docker_compose_domains from application_previews
  where deleted_at is null and coalesce(docker_compose_domains, '') <> ''
union all select fqdn from service_applications where deleted_at is null and coalesce(fqdn, '') <> '';
"""

# Standalone databases share these columns. destination_type is the PHP class
# name; only StandaloneDocker destinations map to a single server.
DB_TABLES = [
    "standalone_postgresqls", "standalone_mysqls", "standalone_mariadbs",
    "standalone_mongodbs", "standalone_redis", "standalone_keydbs",
    "standalone_dragonflies", "standalone_clickhouses",
]


def port_sql():
    rows = ["select ports_mappings, null::int as public_port, destination_id, destination_type,"
            " (to_jsonb(t)->>'deleted_at') as del from applications t"]
    for table in DB_TABLES:
        rows.append(
            "select ports_mappings, case when is_public then public_port end, destination_id,"
            f" destination_type, (to_jsonb(t)->>'deleted_at') from {table} t")
    union = "\n  union all ".join(rows)
    return f"""
select s.ip, coalesce(x.ports_mappings, ''), coalesce(x.public_port::text, '')
from ({union}) x
join standalone_dockers d on d.id = x.destination_id and x.destination_type like '%StandaloneDocker'
join servers s on s.id = d.server_id
where x.del is null and (coalesce(x.ports_mappings, '') <> '' or x.public_port is not null)
union all
select s.ip, '', sd.public_port::text
from service_databases sd
join services sv on sv.id = sd.service_id
join standalone_dockers d on d.id = sv.destination_id and sv.destination_type like '%StandaloneDocker'
join servers s on s.id = d.server_id
where sd.is_public and sd.public_port is not null
  and sd.deleted_at is null and (to_jsonb(sv)->>'deleted_at') is null;
"""


def psql(sql):
    """Run SQL in coolify-db and return rows as lists of fields."""
    out = subprocess.run(
        [PODMAN, "exec", "-i", "coolify-db", "sh", "-c",
         'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "\t" -v ON_ERROR_STOP=1'],
        input=sql, capture_output=True, text=True, timeout=30, check=True,
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line]


HOST_RE = re.compile(r"https?://([A-Za-z0-9.*-]+)")


def coolify_domains():
    hosts = set()
    for (blob,) in psql(DOMAIN_SQL):
        hosts.update(h.lower().strip(".") for h in HOST_RE.findall(blob))
    return hosts


def in_zones(host):
    return any(host == z or host.endswith("." + z) for z in ZONES)


# --- serve -----------------------------------------------------------------

class AskCache:
    def __init__(self, ttl):
        self.ttl = ttl
        self.at = 0.0
        self.hosts = set()

    def get(self):
        if time.monotonic() - self.at > self.ttl:
            self.hosts = coolify_domains()
            self.at = time.monotonic()
        return self.hosts


def serve(args):
    cache = AskCache(args.cache_ttl)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/health":
                return self.reply(200, "ok")
            if url.path != "/ask":
                return self.reply(404, "not found")
            domain = urllib.parse.parse_qs(url.query).get("domain", [""])[0].lower().strip(".")
            if not domain or not in_zones(domain):
                return self.reply(403, "zone not allowed")
            try:
                hosts = cache.get()
                # A new app's domain may be younger than the cache.
                if domain not in hosts:
                    cache.at = 0.0
                    hosts = cache.get()
            except Exception as e:  # noqa: BLE001 - refuse rather than crash
                print(f"ask {domain}: coolify lookup failed: {e}", file=sys.stderr, flush=True)
                return self.reply(503, "lookup failed")
            if domain in hosts:
                return self.reply(200, "ok")
            return self.reply(404, "unknown domain")

        def reply(self, code, body):
            data = (body + "\n").encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *a):
            if "/health" not in self.path:
                print(f"{self.address_string()} {fmt % a}", file=sys.stderr, flush=True)

    # Refreshing the domain list per request is cheap but not free; a cache
    # miss above forces one refresh at most.
    ThreadingHTTPServer((args.listen, args.port), Handler).serve_forever()


# --- nat -------------------------------------------------------------------

def parse_mappings(spec):
    """Host ports (proto, port) published by a Docker-style ports list.

    Accepts "8080:80", "8080:80/udp", "0.0.0.0:8080:80", "8000-8002:8000-8002"
    and a bare "8080". Mappings bound to loopback are not public, so skipped.
    """
    out = set()
    for entry in spec.split(","):
        entry = entry.strip()
        if not entry:
            continue
        entry, _, proto = entry.partition("/")
        proto = (proto or "tcp").lower()
        parts = entry.split(":")
        if len(parts) == 3:
            if parts[0].startswith("127.") or parts[0] in ("localhost", "[::1]"):
                continue
            host = parts[1]
        else:
            host = parts[0]
        lo, _, hi = host.partition("-")
        try:
            lo, hi = int(lo), int(hi or lo)
        except ValueError:
            print(f"skipping unparseable port mapping {entry!r}", file=sys.stderr)
            continue
        if hi - lo >= MAX_RANGE:
            print(f"skipping port range {entry!r}: more than {MAX_RANGE} ports", file=sys.stderr)
            continue
        protos = ["tcp", "udp"] if proto in ("tcp+udp", "both") else [proto]
        for p in protos:
            if p in ("tcp", "udp"):
                out.update((p, port) for port in range(lo, hi + 1))
    return out


def wanted_rules():
    rules = set()
    for ip, mappings, public_port in psql(port_sql()):
        if ip not in MANAGED_NODES:
            continue
        ports = parse_mappings(mappings)
        if public_port:
            ports.add(("tcp", int(public_port)))
        rules.update((proto, ip, port) for proto, port in ports)
    allowed = set()
    for proto, ip, port in sorted(rules):
        if port in BLOCKED_PORTS or not 1 <= port <= 65535:
            print(f"refusing {proto}/{port} -> {ip}: blocked port", file=sys.stderr)
        else:
            allowed.add((proto, ip, port))
    return allowed


NAT_RE = re.compile(
    r"^ip nat inside source static (tcp|udp) (\d+\.\d+\.\d+\.\d+) (\d+) interface (\S+) (\d+)", re.M)


def router(commands):
    """Send IOS commands on stdin (IOS rejects a remote command argument)."""
    cmd = [SSH, "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    if ROUTER_SSH_CONFIG:
        cmd += ["-F", ROUTER_SSH_CONFIG]
    cmd.append(ROUTER_HOST)
    res = subprocess.run(cmd, input="\n".join(commands + ["exit"]) + "\n",
                         capture_output=True, text=True, timeout=90)
    if res.returncode != 0:
        raise RuntimeError(f"router ssh exited {res.returncode}: {res.stderr.strip()}")
    if re.search(r"^% (Invalid|Incomplete|Ambiguous)", res.stdout, re.M):
        raise RuntimeError(f"router rejected a command:\n{res.stdout}")
    return res.stdout


def router_rules():
    """Static NAT lines on the router as {(proto, outside_port): (ip, inside_port, iface)}."""
    out = router(["terminal length 0", "show running-config | include ^ip nat inside source static"])
    return {(m[0], int(m[4])): (m[1], int(m[2]), m[3]) for m in NAT_RE.findall(out)}


def rule_line(proto, ip, port):
    return f"ip nat inside source static {proto} {ip} {port} interface {WAN_INTERFACE} {port}"


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, STATE_FILE)


def nat(args):
    wanted = wanted_rules()
    wanted_key = sorted([list(r) for r in wanted])
    state = load_state()
    fresh = time.time() - state.get("checked_at", 0) < args.recheck
    if state.get("wanted") == wanted_key and fresh:
        print(f"no change ({len(wanted)} rules)")
        return 0

    current = router_rules()
    add, remove, conflicts = [], [], []
    for proto, ip, port in sorted(wanted):
        have = current.get((proto, port))
        if have is None:
            add.append(rule_line(proto, ip, port))
        elif have != (ip, port, WAN_INTERFACE):
            conflicts.append(f"{proto}/{port} already maps to {have[0]}:{have[1]}")
    for (proto, port), (ip, inside, iface) in sorted(current.items()):
        if ip in MANAGED_NODES and (proto, ip, port) not in wanted:
            remove.append(f"no ip nat inside source static {proto} {ip} {inside} interface {iface} {port}")

    for c in conflicts:
        print(f"conflict, not forwarding: {c}", file=sys.stderr)
    if args.dry_run:
        print("\n".join(["dry run:"] + remove + add))
        return 0
    if add or remove:
        # Removals first so a moved port is free before it is re-added.
        router(["configure terminal"] + remove + add + ["end"])
        for line in remove + add:
            print(line)
    save_state({"wanted": wanted_key, "checked_at": time.time(), "conflicts": conflicts})
    print(f"in sync: {len(wanted)} wanted, {len(add)} added, {len(remove)} removed, {len(conflicts)} conflicts")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--listen", default="127.0.0.1")
    s.add_argument("--port", type=int, default=9180)
    s.add_argument("--cache-ttl", type=float, default=60)
    n = sub.add_parser("nat")
    n.add_argument("--recheck", type=float, default=900, help="seconds between router checks when nothing changed")
    n.add_argument("--dry-run", action="store_true")
    sub.add_parser("domains")
    args = ap.parse_args()
    if args.cmd == "serve":
        serve(args)
    elif args.cmd == "nat":
        return nat(args)
    elif args.cmd == "domains":
        for h in sorted(coolify_domains()):
            print(h, "" if in_zones(h) else "(outside allowed zones)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
