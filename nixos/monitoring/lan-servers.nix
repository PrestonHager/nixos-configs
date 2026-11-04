# Servers documented on serverdocs (other than ace, which has its own Ace
# folder). Drives three things:
#   - prometheus-config.nix: the `node-hosts` scrape job and the extra TCP probes
#     in `blackbox-tcp-lan-hosts`, all labelled host=… and lifecycle=…
#   - grafana/server-dashboards.nix: one "Server — <name>" dashboard per entry
#   - LAN uptime %: only lifecycle="active" hosts count (lan-status.json), and
#     the scrape-down alert ignores planned/disconnected ones.
#
# lifecycle: "active" (in service), "disconnected" (built, currently unplugged),
# "planned" (not installed yet). Flip it to "active" when a host goes into
# service; its dashboard fills in by itself once node_exporter answers.
{
  crux = {
    title = "crux";
    ip = "192.168.5.6";
    role = "Hydrodactyl Wings node (Dell OptiPlex)";
    lifecycle = "active";
    docs = "pterodactyl-nodes/crux.html";
    # Off until crux is deployed with the :9100 rule for ace in
    # crux-prometheus.nix; flip to true after that deploy.
    nodeExporter = false;
    # crux's SSH/Wings/SFTP are already probed by blackbox-tcp-crux.
    probes = [ ];
  };
  elara = {
    title = "elara";
    ip = "192.168.5.8";
    role = "Hydrodactyl Wings node (Dell OptiPlex)";
    lifecycle = "active";
    docs = "pterodactyl-nodes/elara.html";
    nodeExporter = true;
    probes = [
      { port = 443; service = "wings"; role = "https"; }
      { port = 2022; service = "wings-sftp"; role = "sftp"; }
    ];
  };
  nova = {
    title = "nova";
    ip = "192.168.5.7";
    role = "Hydrodactyl Wings node (physically disconnected; config kept as a template)";
    lifecycle = "disconnected";
    docs = "pterodactyl-nodes/nova.html";
    nodeExporter = true;
    probes = [ ];
  };
  zenith = {
    title = "zenith";
    ip = "192.168.5.9";
    role = "Planned Hydrodactyl Wings node (Dell OptiPlex)";
    lifecycle = "planned";
    docs = "pterodactyl-nodes/zenith.html";
    nodeExporter = true;
    probes = [ ];
  };
  mars = {
    title = "mars";
    ip = "192.168.5.15";
    role = "PowerEdge R410, Coolify deploy server";
    lifecycle = "active";
    docs = "poweredge/mars.html";
    nodeExporter = true;
    probes = [
      { port = 22; service = "ssh"; role = "management"; }
    ];
    idrac = { ip = "192.168.5.11"; docs = "poweredge/mars-idrac.html"; lifecycle = "active"; };
  };
  sally = {
    title = "sally";
    ip = "192.168.5.16";
    role = "PowerEdge R320 (not connected yet)";
    lifecycle = "planned";
    docs = "poweredge/sally.html";
    nodeExporter = true;
    probes = [
      { port = 22; service = "ssh"; role = "management"; }
    ];
    idrac = { ip = "192.168.5.12"; docs = "poweredge/sally-idrac.html"; lifecycle = "planned"; };
  };
}
