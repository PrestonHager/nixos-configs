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
         While Coolify wants no ports it never logs in at all.

         The router account needs `show running-config` and `configure
         terminal` (privilege 15, or a custom level granting both).

  dns    Gives every Coolify hostname inside the zones a CNAME, so a new
         app domain resolves without editing DNS by hand: in Cloudflare
         (public, -> COOLIFY_EDGE_PUBLIC_TARGET, DNS only) and in Technitium
         (LAN, -> COOLIFY_EDGE_LAN_TARGET). Names under a wildcard that already
         exists (*.apps) are skipped. A name that already has records it did
         not create is left alone and reported. Cloudflare records it creates
         carry the comment COOLIFY_EDGE_DNS_COMMENT, and only records with that
         comment are ever deleted; Technitium records it created are tracked in
         its state file (Technitium's zone sync can re-import the zone, so they
         are re-checked like the NAT rules).

Guard rails (all from the environment):

  COOLIFY_EDGE_TEAM_IDS        only domains/ports of these Coolify teams
                               (empty: all teams)
  COOLIFY_EDGE_DENY_HOSTS      exact names never accepted (ace's own vhosts)
  COOLIFY_EDGE_DENY_LABELS     names with any of these labels below the zone
                               are never accepted (login, admin, vault, ...)
  COOLIFY_EDGE_FORWARD_PUBLIC_DATABASES
                               "1" to forward database ports (public port or
                               port mappings of a database); default off
  COOLIFY_EDGE_MAX_PORTS       refuse to sync NAT when more ports are wanted
  COOLIFY_EDGE_MAX_RANGE       skip port ranges with more ports than this

Every change to the router or to DNS is logged at warning priority.

Configuration comes from the environment (set by nixos/containers/coolify-edge.nix).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
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
DNS_STATE_FILE = os.environ.get("COOLIFY_EDGE_DNS_STATE", "/var/lib/coolify-edge/dns.json")
DNS_SKIP_SUFFIXES = [s.lower().strip(".") for s in os.environ.get("COOLIFY_EDGE_DNS_SKIP", "").split()]
PUBLIC_TARGET = os.environ.get("COOLIFY_EDGE_PUBLIC_TARGET", "")
LAN_TARGET = os.environ.get("COOLIFY_EDGE_LAN_TARGET", "")
DNS_COMMENT = os.environ.get("COOLIFY_EDGE_DNS_COMMENT", "managed by coolify-edge")
TECHNITIUM_API = os.environ.get("COOLIFY_EDGE_TECHNITIUM_API", "http://127.0.0.1:5380")
TECHNITIUM_PASSWORD_FILE = os.environ.get("COOLIFY_EDGE_TECHNITIUM_PASSWORD_FILE", "")
TEAM_IDS = [int(t) for t in os.environ.get("COOLIFY_EDGE_TEAM_IDS", "").split()]
DENY_HOSTS = {h.lower().strip(".") for h in os.environ.get("COOLIFY_EDGE_DENY_HOSTS", "").split()}
DENY_LABELS = {lbl.lower() for lbl in os.environ.get("COOLIFY_EDGE_DENY_LABELS", "").split()}
FORWARD_PUBLIC_DATABASES = os.environ.get("COOLIFY_EDGE_FORWARD_PUBLIC_DATABASES", "0") == "1"
MAX_PORTS = int(os.environ.get("COOLIFY_EDGE_MAX_PORTS", "50"))
MAX_RANGE = int(os.environ.get("COOLIFY_EDGE_MAX_RANGE", "20"))


def warn(msg):
    """Log at warning priority (journald reads the <4> prefix)."""
    print(f"<4>{msg}", file=sys.stderr, flush=True)


def team_filter(env_col):
    """SQL condition limiting env_col (an environment id) to TEAM_IDS."""
    if not TEAM_IDS:
        return "true"
    ids = ", ".join(str(i) for i in TEAM_IDS)
    return (f"({env_col})::bigint in (select e.id from environments e"
            f" join projects p on p.id = e.project_id where p.team_id in ({ids}))")


def domain_sql():
    app_ok = team_filter("to_jsonb(a)->>'environment_id'")
    svc_ok = team_filter("to_jsonb(s)->>'environment_id'")
    return f"""
select a.fqdn from applications a
  where a.deleted_at is null and coalesce(a.fqdn, '') <> '' and {app_ok}
union all select a.docker_compose_domains from applications a
  where a.deleted_at is null and coalesce(a.docker_compose_domains, '') <> '' and {app_ok}
union all select p.fqdn from application_previews p join applications a on a.id = p.application_id
  where p.deleted_at is null and coalesce(p.fqdn, '') <> '' and {app_ok}
union all select p.docker_compose_domains from application_previews p join applications a on a.id = p.application_id
  where p.deleted_at is null and coalesce(p.docker_compose_domains, '') <> '' and {app_ok}
union all select sa.fqdn from service_applications sa join services s on s.id = sa.service_id
  where sa.deleted_at is null and coalesce(sa.fqdn, '') <> '' and {svc_ok};
"""

# Standalone databases share these columns. destination_type is the PHP class
# name; only StandaloneDocker destinations map to a single server.
DB_TABLES = [
    "standalone_postgresqls", "standalone_mysqls", "standalone_mariadbs",
    "standalone_mongodbs", "standalone_redis", "standalone_keydbs",
    "standalone_dragonflies", "standalone_clickhouses",
]


def port_sql():
    """Rows (kind, server ip, ports_mappings, public_port); kind is app or db."""
    rows = ["select 'app' as kind, ports_mappings, null::int as public_port, destination_id,"
            " destination_type, (to_jsonb(t)->>'deleted_at') as del,"
            " (to_jsonb(t)->>'environment_id') as env from applications t"]
    for table in DB_TABLES:
        rows.append(
            "select 'db', ports_mappings, case when is_public then public_port end, destination_id,"
            f" destination_type, (to_jsonb(t)->>'deleted_at'), (to_jsonb(t)->>'environment_id') from {table} t")
    union = "\n  union all ".join(rows)
    return f"""
select x.kind, s.ip, coalesce(x.ports_mappings, ''), coalesce(x.public_port::text, '')
from ({union}) x
join standalone_dockers d on d.id = x.destination_id and x.destination_type like '%StandaloneDocker'
join servers s on s.id = d.server_id
where x.del is null and (coalesce(x.ports_mappings, '') <> '' or x.public_port is not null)
  and {team_filter("x.env")}
union all
select 'db', s.ip, '', sd.public_port::text
from service_databases sd
join services sv on sv.id = sd.service_id
join standalone_dockers d on d.id = sv.destination_id and sv.destination_type like '%StandaloneDocker'
join servers s on s.id = d.server_id
where sd.is_public and sd.public_port is not null
  and sd.deleted_at is null and (to_jsonb(sv)->>'deleted_at') is null
  and {team_filter("to_jsonb(sv)->>'environment_id'")};
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
    for (blob,) in psql(domain_sql()):
        hosts.update(h.lower().strip(".") for h in HOST_RE.findall(blob))
    return hosts


def in_zones(host):
    return any(host == z or host.endswith("." + z) for z in ZONES)


def denied(host):
    """Why host may never be routed to Coolify, or None if it may."""
    if host in DENY_HOSTS:
        return "served by ace itself"
    if host in ZONES:
        return "zone apex"
    zone = max((z for z in ZONES if host.endswith("." + z)), key=len, default=None)
    labels = host[: -len(zone) - 1].split(".") if zone else host.split(".")
    for label in labels:
        if label in DENY_LABELS:
            return f"reserved label {label!r}"
    return None


# --- serve -----------------------------------------------------------------

class AskCache:
    """Domain list for the ask endpoint, refreshed from Coolify's database.

    A miss forces a refresh (a new app's domain may be younger than the
    cache), but at most once per `min_refresh` seconds, and the miss is then
    remembered for `negative_ttl` seconds. So a flood of unknown SNI names
    runs `podman exec psql` a bounded number of times instead of once per
    request. One lock serialises refreshes across the server's threads.
    """

    NEGATIVE_MAX = 10000

    def __init__(self, ttl, min_refresh, negative_ttl):
        self.ttl = ttl
        self.min_refresh = min_refresh
        self.negative_ttl = negative_ttl
        self.at = float("-inf")
        self.hosts = set()
        self.negative = {}
        self.lock = threading.Lock()

    def _refresh(self, now):
        self.hosts = coolify_domains()
        self.at = now
        # New domains may have appeared; forget remembered misses.
        self.negative.clear()

    def known(self, domain):
        with self.lock:
            now = time.monotonic()
            if self.negative.get(domain, 0) > now:
                return False
            if now - self.at > self.ttl:
                self._refresh(now)
            if domain in self.hosts:
                return True
            if now - self.at >= self.min_refresh:
                self._refresh(now)
                if domain in self.hosts:
                    return True
            if len(self.negative) >= self.NEGATIVE_MAX:
                self.negative = {d: t for d, t in self.negative.items() if t > now}
                if len(self.negative) >= self.NEGATIVE_MAX:
                    self.negative.clear()
            self.negative[domain] = now + self.negative_ttl
            return False


def serve(args):
    cache = AskCache(args.cache_ttl, args.min_refresh, args.negative_ttl)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/health":
                return self.reply(200, "ok")
            if url.path != "/ask":
                return self.reply(404, "not found")
            domain = urllib.parse.parse_qs(url.query).get("domain", [""])[0].lower().strip(".")
            if not domain or len(domain) > 253 or not in_zones(domain):
                return self.reply(403, "zone not allowed")
            reason = denied(domain)
            if reason:
                return self.reply(403, f"denied: {reason}")
            try:
                ok = cache.known(domain)
            except Exception as e:  # noqa: BLE001 - refuse rather than crash
                print(f"ask {domain}: coolify lookup failed: {e}", file=sys.stderr, flush=True)
                return self.reply(503, "lookup failed")
            if ok:
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
        if hi < lo or hi - lo >= MAX_RANGE:
            print(f"skipping port range {entry!r}: more than COOLIFY_EDGE_MAX_RANGE={MAX_RANGE} ports",
                  file=sys.stderr)
            continue
        protos = ["tcp", "udp"] if proto in ("tcp+udp", "both") else [proto]
        for p in protos:
            if p in ("tcp", "udp"):
                out.update((p, port) for port in range(lo, hi + 1))
    return out


def wanted_rules():
    rules = set()
    skipped_db = 0
    for kind, ip, mappings, public_port in psql(port_sql()):
        if ip not in MANAGED_NODES:
            continue
        if kind == "db" and not FORWARD_PUBLIC_DATABASES:
            # Databases on the internet are opt-in (COOLIFY_EDGE_FORWARD_PUBLIC_DATABASES=1).
            skipped_db += 1
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
    if skipped_db:
        print(f"not forwarding {skipped_db} database(s) with published ports "
              "(COOLIFY_EDGE_FORWARD_PUBLIC_DATABASES is off)", file=sys.stderr)
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


def load_state(path=STATE_FILE):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state, path=STATE_FILE):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


def nat(args):
    wanted = wanted_rules()
    if len(wanted) > MAX_PORTS:
        warn(f"refusing to sync NAT: Coolify wants {len(wanted)} forwarded ports, more than "
             f"COOLIFY_EDGE_MAX_PORTS={MAX_PORTS}; router left unchanged")
        return 1
    wanted_key = sorted([list(r) for r in wanted])
    state = load_state()
    fresh = time.time() - state.get("checked_at", 0) < args.recheck
    # Nothing wanted now or last time: no rule of ours can be on the router.
    if state.get("wanted", []) == wanted_key and (fresh or not wanted):
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
            warn(f"router NAT changed: {line}")
    save_state({"wanted": wanted_key, "checked_at": time.time(), "conflicts": conflicts})
    print(f"in sync: {len(wanted)} wanted, {len(add)} added, {len(remove)} removed, {len(conflicts)} conflicts")
    return 0


# --- dns -------------------------------------------------------------------

def http_json(method, url, headers=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=dict(headers or {}))
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.load(res)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {url.split('?')[0]}: HTTP {e.code} {e.read()[:300]!r}") from None


class Cloudflare:
    API = "https://api.cloudflare.com/client/v4"

    def __init__(self, zone):
        token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
        if not token:
            raise RuntimeError("CLOUDFLARE_API_TOKEN is not set")
        self.headers = {"Authorization": f"Bearer {token}"}
        found = self.call("GET", "/zones?" + urllib.parse.urlencode({"name": zone}))
        if not found:
            raise RuntimeError(f"Cloudflare zone {zone} not visible to the token")
        self.zone_id = found[0]["id"]

    def call(self, method, path, body=None):
        res = http_json(method, self.API + path, self.headers, body)
        if not res.get("success"):
            raise RuntimeError(f"Cloudflare {method} {path.split('?')[0]}: {res.get('errors')}")
        return res["result"]

    def records(self, name):
        return self.call("GET", f"/zones/{self.zone_id}/dns_records?"
                         + urllib.parse.urlencode({"name": name, "per_page": 100}))

    def managed(self):
        return self.call("GET", f"/zones/{self.zone_id}/dns_records?"
                         + urllib.parse.urlencode({"type": "CNAME", "comment.exact": DNS_COMMENT,
                                                   "per_page": 1000}))

    def add(self, name, target):
        self.call("POST", f"/zones/{self.zone_id}/dns_records", {
            "type": "CNAME", "name": name, "content": target, "ttl": 1,
            "proxied": False, "comment": DNS_COMMENT,
        })

    def delete(self, record_id):
        self.call("DELETE", f"/zones/{self.zone_id}/dns_records/{record_id}")


class Technitium:
    def __init__(self):
        with open(TECHNITIUM_PASSWORD_FILE) as f:
            password = f.read().strip()
        # Form POST, so the password never appears in a URL.
        form = urllib.parse.urlencode({"user": "admin", "pass": password}).encode()
        with urllib.request.urlopen(TECHNITIUM_API + "/api/user/login", data=form, timeout=30) as res:
            body = json.load(res)
        if body.get("status") != "ok":
            raise RuntimeError(f"Technitium login: {body.get('errorMessage', body.get('status'))}")
        self.token = body["token"]

    def call(self, path, **params):
        res = http_json("GET", TECHNITIUM_API + path + "?" + urllib.parse.urlencode(params),
                        {"Authorization": f"Bearer {self.token}"})
        if res.get("status") != "ok":
            raise RuntimeError(f"Technitium {path}: {res.get('errorMessage', res.get('status'))}")
        return res

    def records(self, zone, name):
        try:
            res = self.call("/api/zones/records/get", zone=zone, domain=name)
        except RuntimeError as e:
            if "No such" in str(e) or "not found" in str(e).lower():
                return []
            raise
        # Only records at exactly this name (get also returns the zone's subtree).
        return [r for r in res["response"]["records"] if r["name"].lower() == name]

    def add(self, zone, name, target):
        self.call("/api/zones/records/add", zone=zone, domain=name, type="CNAME",
                  cname=target, ttl=300, overwrite="false", comments=DNS_COMMENT)

    def delete(self, zone, name, target):
        self.call("/api/zones/records/delete", zone=zone, domain=name, type="CNAME", cname=target)

    def logout(self):
        try:
            self.call("/api/user/logout")
        except Exception:  # noqa: BLE001 - the session expires anyway
            pass


def zone_of(host):
    return max((z for z in ZONES if host == z or host.endswith("." + z)), key=len, default=None)


def dns_wanted():
    """(names to publish, {refused name: reason})."""
    out, refused = set(), {}
    for host in coolify_domains():
        if "*" in host or host in ZONES or not zone_of(host):
            continue
        if any(host.endswith("." + s) for s in DNS_SKIP_SUFFIXES):
            continue
        reason = denied(host)
        if reason:
            refused[host] = reason
            continue
        out.add(host)
    return out, refused


def dns(args):
    wanted, refused = dns_wanted()
    state = load_state(DNS_STATE_FILE)
    # Report refused names when the set changes, not every minute.
    if sorted(refused) != state.get("refused", []):
        for name, reason in sorted(refused.items()):
            warn(f"not publishing {name}: {reason}")
    lan_ours = set(state.get("lan", []))
    fresh = time.time() - state.get("checked_at", 0) < args.recheck
    if (set(state.get("wanted", [])) == wanted and sorted(refused) == state.get("refused", [])
            and (fresh or not (wanted or lan_ours))):
        print(f"no change ({len(wanted)} names)")
        return 0

    log, conflicts = [], []

    def act(msg, fn):
        if args.dry_run:
            log.append("dry run: " + msg)
            return
        fn()
        warn(f"DNS changed: {msg}")
        log.append(msg)

    # Public: Cloudflare.
    for zone in sorted({zone_of(h) for h in wanted} | set(ZONES)):
        cf = Cloudflare(zone)
        managed = {r["name"].lower(): r for r in cf.managed()}
        for name, rec in sorted(managed.items()):
            if zone_of(name) == zone and name not in wanted:
                act(f"cloudflare: delete {name}", lambda r=rec: cf.delete(r["id"]))
        for name in sorted(h for h in wanted if zone_of(h) == zone):
            rec = managed.get(name)
            if rec and rec["content"].lower() == PUBLIC_TARGET.lower():
                continue
            if rec:
                act(f"cloudflare: repoint {name}", lambda r=rec: cf.delete(r["id"]))
            elif cf.records(name):
                conflicts.append(f"cloudflare: {name} already has records not managed by coolify-edge")
                continue
            act(f"cloudflare: add {name} CNAME {PUBLIC_TARGET}", lambda n=name: cf.add(n, PUBLIC_TARGET))

    # LAN: Technitium (authoritative for the zones on the LAN).
    lan_now = set()
    if TECHNITIUM_PASSWORD_FILE:
        tn = Technitium()
        try:
            for name in sorted(lan_ours - wanted):
                act(f"technitium: delete {name}", lambda n=name: tn.delete(zone_of(n), n, LAN_TARGET))
            for name in sorted(wanted):
                recs = tn.records(zone_of(name), name)
                if any(r["type"] == "CNAME" and r["rData"].get("cname", "").lower() == LAN_TARGET.lower()
                       for r in recs):
                    if name in lan_ours or any(DNS_COMMENT in (r.get("comments") or "") for r in recs):
                        lan_now.add(name)
                    continue
                if recs:
                    conflicts.append(f"technitium: {name} already has records not managed by coolify-edge")
                    continue
                act(f"technitium: add {name} CNAME {LAN_TARGET}", lambda n=name: tn.add(zone_of(n), n, LAN_TARGET))
                lan_now.add(name)
        finally:
            tn.logout()

    if args.dry_run:
        for line in log:
            print(line)
    for c in conflicts:
        print(f"conflict: {c}", file=sys.stderr)
    if not args.dry_run:
        save_state({"wanted": sorted(wanted), "lan": sorted(lan_now), "checked_at": time.time(),
                    "conflicts": conflicts, "refused": sorted(refused)}, DNS_STATE_FILE)
    print(f"in sync: {len(wanted)} names, {len(log)} changes, {len(conflicts)} conflicts")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--listen", default="127.0.0.1")
    s.add_argument("--port", type=int, default=9180)
    s.add_argument("--cache-ttl", type=float, default=60)
    s.add_argument("--min-refresh", type=float, default=5,
                   help="seconds between database refreshes forced by unknown names")
    s.add_argument("--negative-ttl", type=float, default=30,
                   help="seconds an unknown name is answered from cache")
    n = sub.add_parser("nat")
    n.add_argument("--recheck", type=float, default=900, help="seconds between router checks when nothing changed")
    n.add_argument("--dry-run", action="store_true")
    d = sub.add_parser("dns")
    d.add_argument("--recheck", type=float, default=900, help="seconds between DNS checks when nothing changed")
    d.add_argument("--dry-run", action="store_true")
    sub.add_parser("domains")
    args = ap.parse_args()
    if args.cmd == "serve":
        serve(args)
    elif args.cmd == "nat":
        return nat(args)
    elif args.cmd == "dns":
        return dns(args)
    elif args.cmd == "domains":
        for h in sorted(coolify_domains()):
            reason = None if in_zones(h) else "outside allowed zones"
            reason = reason or denied(h)
            print(h, f"(refused: {reason})" if reason else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
