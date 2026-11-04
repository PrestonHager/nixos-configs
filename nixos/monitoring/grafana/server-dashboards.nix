# One "Server — <name>" Grafana dashboard per entry in ../lan-servers.nix,
# provisioned into the Servers folder (nixos/monitoring/default.nix).
# Panels read node_exporter (job node-hosts) and the blackbox TCP probes, all
# selected by the host label, so a planned or disconnected host shows "No data"
# until it comes online and then fills in without changes here.
{ pkgs, lib }:

let
  servers = import ../lan-servers.nix;
  ds = { type = "prometheus"; uid = "prometheus"; };
  docsBase = "https://serverdocs.prestonhager.com/";

  statusText = name: s:
    let
      note = {
        active = "In service. Counted in the LAN uptime percentage.";
        disconnected = "**Disconnected.** Built but not plugged in, so every panel shows *No data*. Not counted in the LAN uptime percentage and does not alert.";
        planned = "**Not installed yet.** Every panel shows *No data* until the host is online. Not counted in the LAN uptime percentage and does not alert.";
      }.${s.lifecycle};
      idrac = lib.optionalString (s ? idrac)
        " · iDRAC `${s.idrac.ip}` ([docs](${docsBase}${s.idrac.docs}))";
    in
    "**${s.title}** · `${s.ip}` · ${s.role} · [serverdocs](${docsBase}${s.docs})${idrac}\n\nLifecycle: `${s.lifecycle}`. ${note}";

  h = name: ''host="${name}"'';
  nodeSel = name: ''job="node-hosts",${h name}'';

  # Grid helper: panels are laid out left to right, 24 columns wide.
  panel = id: x: y: w: hgt: attrs: { inherit id; gridPos = { inherit x y w; h = hgt; }; datasource = ds; } // attrs;

  target = refId: expr: legend: { inherit refId expr; legendFormat = legend; datasource = ds; };

  stat = { id, x, y, w ? 4, title, expr, unit ? "none", mappings ? [ ], thresholds ? null, decimals ? null }:
    panel id x y w 4 {
      type = "stat";
      inherit title;
      targets = [ (target "A" expr "") ];
      options = { reduceOptions = { calcs = [ "lastNotNull" ]; fields = ""; values = false; }; colorMode = "background"; graphMode = "none"; textMode = "value"; };
      fieldConfig = {
        defaults = { inherit unit mappings; noValue = "No data"; color = { mode = "thresholds"; }; }
          // lib.optionalAttrs (decimals != null) { inherit decimals; }
          // lib.optionalAttrs (thresholds != null) { inherit thresholds; };
        overrides = [ ];
      };
    };

  upDown = [{ type = "value"; options = { "0" = { text = "Down"; color = "red"; }; "1" = { text = "Up"; color = "green"; }; }; }];
  steps = s: { mode = "absolute"; steps = s; };

  timeseries = { id, x, y, w ? 12, hgt ? 8, title, targets, unit ? "none", min ? null, max ? null }:
    panel id x y w hgt {
      type = "timeseries";
      inherit title targets;
      options = { legend = { displayMode = "list"; placement = "bottom"; showLegend = true; }; tooltip = { mode = "multi"; sort = "none"; }; };
      fieldConfig = {
        defaults = { inherit unit; custom = { fillOpacity = 10; lineWidth = 1; showPoints = "never"; }; }
          // lib.optionalAttrs (min != null) { inherit min; }
          // lib.optionalAttrs (max != null) { inherit max; };
        overrides = [ ];
      };
    };

  dashboard = name: s: {
    uid = "server-${name}";
    title = "Server — ${s.title}";
    tags = [ "server" "lan" s.lifecycle ];
    timezone = "browser";
    schemaVersion = 39;
    version = 1;
    editable = false;
    refresh = "1m";
    time = { from = "now-24h"; to = "now"; };
    links = [
      { title = "LAN Status"; type = "link"; url = "/d/lan-status"; icon = "dashboard"; }
      { title = "serverdocs"; type = "link"; url = "${docsBase}${s.docs}"; icon = "doc"; targetBlank = true; }
    ];
    templating.list = [ ];
    annotations.list = [ ];
    panels = [
      (panel 1 0 0 24 3 {
        type = "text";
        title = "";
        options = { mode = "markdown"; content = statusText name s; };
      })
      # Row 1: at-a-glance stats.
      (stat {
        id = 2; x = 0; y = 3; title = "Reachable (any probe)";
        expr = "max(probe_success{${h name},service!=\"idrac\"}) or max(up{${nodeSel name}})";
        mappings = upDown;
        thresholds = steps [ { color = "red"; value = null; } { color = "green"; value = 1; } ];
      })
      (stat {
        id = 3; x = 4; y = 3; title = "node_exporter";
        expr = "up{${nodeSel name}}";
        mappings = upDown;
        thresholds = steps [ { color = "red"; value = null; } { color = "green"; value = 1; } ];
      })
      (stat {
        id = 4; x = 8; y = 3; title = "Uptime";
        expr = "time() - node_boot_time_seconds{${nodeSel name}}";
        unit = "s";
      })
      (stat {
        id = 5; x = 12; y = 3; title = "Probe uptime (24h)";
        expr = "avg(avg_over_time(probe_success{${h name},service!=\"idrac\"}[24h])) * 100";
        unit = "percent"; decimals = 2;
        thresholds = steps [ { color = "red"; value = null; } { color = "orange"; value = 95; } { color = "green"; value = 99.5; } ];
      })
      (stat {
        id = 6; x = 16; y = 3; title = "Failed systemd units";
        expr = ''count(node_systemd_unit_state{${nodeSel name},state="failed"} == 1) or (up{${nodeSel name}} * 0)'';
        thresholds = steps [ { color = "green"; value = null; } { color = "red"; value = 1; } ];
      })
      (stat {
        id = 7; x = 20; y = 3; title = "Root disk used";
        expr = ''100 - 100 * node_filesystem_avail_bytes{${nodeSel name},mountpoint="/"} / node_filesystem_size_bytes{${nodeSel name},mountpoint="/"}'';
        unit = "percent"; decimals = 1;
        thresholds = steps [ { color = "green"; value = null; } { color = "orange"; value = 80; } { color = "red"; value = 90; } ];
      })
      # Row 2: CPU and memory.
      (timeseries {
        id = 8; x = 0; y = 7; title = "CPU busy"; unit = "percent"; min = 0; max = 100;
        targets = [ (target "A" ''100 * (1 - avg(rate(node_cpu_seconds_total{${nodeSel name},mode="idle"}[5m])))'' "busy") ];
      })
      (timeseries {
        id = 9; x = 12; y = 7; title = "Memory used"; unit = "percent"; min = 0; max = 100;
        targets = [ (target "A" "100 * (1 - node_memory_MemAvailable_bytes{${nodeSel name}} / node_memory_MemTotal_bytes{${nodeSel name}})" "used") ];
      })
      # Row 3: load and network.
      (timeseries {
        id = 10; x = 0; y = 15; title = "Load average";
        targets = [
          (target "A" "node_load1{${nodeSel name}}" "1m")
          (target "B" "node_load5{${nodeSel name}}" "5m")
          (target "C" "node_load15{${nodeSel name}}" "15m")
        ];
      })
      (timeseries {
        id = 11; x = 12; y = 15; title = "Network (all non-loopback interfaces)"; unit = "Bps";
        targets = [
          (target "A" ''sum(rate(node_network_receive_bytes_total{${nodeSel name},device!~"lo|veth.*|docker.*|br-.*"}[5m]))'' "receive")
          (target "B" ''sum(rate(node_network_transmit_bytes_total{${nodeSel name},device!~"lo|veth.*|docker.*|br-.*"}[5m]))'' "transmit")
        ];
      })
      # Row 4: filesystems and probes.
      (timeseries {
        id = 12; x = 0; y = 23; title = "Filesystem used"; unit = "percent"; min = 0; max = 100;
        targets = [ (target "A" ''100 - 100 * node_filesystem_avail_bytes{${nodeSel name},fstype!~"tmpfs|ramfs|overlay|squashfs|vfat"} / node_filesystem_size_bytes{${nodeSel name},fstype!~"tmpfs|ramfs|overlay|squashfs|vfat"}'' "{{mountpoint}}") ];
      })
      (timeseries {
        id = 13; x = 12; y = 23; title = "Service probes (1 = up)"; min = 0; max = 1;
        targets = [ (target "A" "probe_success{${h name}}" "{{service}} ({{instance}})") ];
      })
    ];
  };

  files = lib.mapAttrs' (name: s: lib.nameValuePair "server-${name}.json" (builtins.toJSON (dashboard name s))) servers;
in
pkgs.runCommand "grafana-server-dashboards" { } ''
  mkdir -p $out
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (f: json: "cp ${pkgs.writeText f json} $out/${f}") files)}
''
