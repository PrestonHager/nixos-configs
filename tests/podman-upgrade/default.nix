# Podman upgrade VM tests (podman 5.8.9 -> 6.x). Not part of any host.
#
#   nix build -f tests/podman-upgrade -A <attr> \
#     --arg nixpkgs <path> --arg newNixpkgs <path> [--arg imgNixpkgs <path>]
#
# Attributes:
#   fresh       boot `nixpkgs`, create state, run check.sh (sandboxed)
#   freshDriver same, as a driver binary; run two of them (old, then new) with
#               --keep-vm-state and one TMPDIR to reboot one disk into the new podman
#   switch      boot `nixpkgs`, live switch-to-configuration into `newNixpkgs`,
#               then reboot (boots `nixpkgs` again = rollback)
{ nixpkgs, newNixpkgs ? nixpkgs, imgNixpkgs ? nixpkgs, tag ? "run" }:
let
  system = "x86_64-linux";
  pkgs = import nixpkgs { inherit system; };
  newPkgs = import newNixpkgs { inherit system; };
  imgPkgs = import imgNixpkgs { inherit system; };

  images = {
    tbox = imgPkgs.dockerTools.buildImage {
      name = "localhost/tbox";
      tag = "1";
      copyToRoot = imgPkgs.buildEnv {
        name = "tbox-root";
        paths = [ imgPkgs.busybox (imgPkgs.writeTextDir "www/index.html" "tbox-ok") ];
      };
      config = {
        Cmd = [ "httpd" "-f" "-p" "80" "-h" "/www" ];
        Env = [ "FOO_VERSION=9.9" "PATH=/bin" ];
        Labels."org.opencontainers.image.version" = "1.2.3";
      };
    };
    postgres = imgPkgs.dockerTools.pullImage {
      imageName = "docker.io/library/postgres";
      imageDigest = "sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229";
      finalImageName = "docker.io/library/postgres";
      finalImageTag = "16-alpine";
      hash = "sha256-r1oR0QMMPNqgWpfLczckCo1ivarraqfOoMKBmm2tC94=";
      os = "linux";
      arch = "amd64";
    };
  };

  nodes = {
    machine = import ./node.nix images;
    client = { pkgs, ... }: {
      virtualisation.memorySize = 512;
      environment.systemPackages = [ pkgs.curl ];
      networking.firewall.allowedTCPPorts = [ 80 ];
      systemd.services.lan-httpd = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.busybox}/bin/httpd -f -p 80 -h ${pkgs.writeTextDir "index.html" "lan-ok"}";
      };
    };
  };

  common = ''
    UNITS = ["pod-zt", "pod-gf", "tnet-network", "ghr-network", "podman-zt-db", "podman-zt-app",
             "podman-gf", "podman-web1", "podman-web2", "podman-tclient", "podman-def1", "podman-ghrc"]

    def wait_all():
        machine.wait_for_unit("multi-user.target")
        client.wait_for_unit("lan-httpd.service")
        for u in UNITS:
            machine.wait_for_unit(u + ".service", timeout=300)
        for c in ["zt-app", "zt-db"]:
            machine.wait_until_succeeds(f"podman inspect {c} --format '{{{{.State.Health.Status}}}}' | grep -qx healthy", timeout=180)
        machine.wait_until_succeeds("podman exec tclient wget -q -O- -T 3 http://web1/", timeout=60)

    def record(tag):
        machine.succeed(
            f"(echo '## pods'; podman pod ps --format '{{{{.Name}}}} {{{{.ID}}}}' | sort; "
            f"echo '## infra'; for p in zt-pod gf-pod ipod; do echo $p $(podman pod inspect $p --format '{{{{.InfraContainerID}}}}' 2>&1); done; "
            f"echo '## networks'; podman network ls --format '{{{{.Name}}}} {{{{.ID}}}}' | sort; "
            f"echo '## volumes'; podman volume ls --format '{{{{.Name}}}}' | sort; "
            f"echo '## containers'; podman ps -a --format '{{{{.Names}}}} {{{{.ID}}}} {{{{.State}}}}' | sort; "
            f"echo '## pod-unit logs'; journalctl -b -u pod-zt -u pod-gf --no-pager -o cat | grep -i -E 'drift|recreat|error' ; "
            f"echo '## failed units'; systemctl --failed --no-legend; true) > /tmp/state-{tag}.txt 2>&1 || true"
        )
        machine.copy_from_machine(f"/tmp/state-{tag}.txt", "")
        print(machine.succeed(f"cat /tmp/state-{tag}.txt"))

    def check(tag):
        machine.execute(f"bash /etc/podman-check.sh > /tmp/check-{tag}.txt 2>&1")
        ext = []
        for label, url in [("ext_web2_any", "http://machine:8182/"), ("ext_web1_lo", "http://machine:8181/"),
                           ("ext_zt_lo", "http://machine:9080/"), ("ext_def1_gw", "http://machine:8190/")]:
            rc, out = client.execute(f"curl -sf -m4 {url}")
            ext.append(f"### {label}\n{out}\n### rc={rc}")
        machine.succeed(f"cat >> /tmp/check-{tag}.txt <<'EOF'\n" + "\n".join(ext) + "\nEOF")
        machine.copy_from_machine(f"/tmp/check-{tag}.txt", "")
        print(machine.succeed(f"cat /tmp/check-{tag}.txt"))

    def make_state():
        machine.succeed("podman volume exists tvol || podman volume create tvol")
        machine.succeed("podman run --rm -v tvol:/d localhost/tbox:1 sh -c 'test -f /d/f || echo hello > /d/f'")
        machine.succeed("podman container exists imper || podman run -d --name imper localhost/tbox:1")
        machine.succeed("podman pod exists ipod || (podman pod create --name ipod -p 127.0.0.1:7070:80 && podman run -d --pod ipod --name ipod-web localhost/tbox:1)")

    def verify_state():
        machine.succeed("podman run --rm -v tvol:/d localhost/tbox:1 cat /d/f | grep -qx hello")
        machine.succeed("podman pod start ipod; podman start imper")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:7070/", timeout=60)
        machine.succeed("podman exec imper true")
  '';

  mk = p: script: p.testers.runNixOSTest {
    name = "podman-upgrade-${tag}";
    inherit nodes;
    testScript = common + script;
  };

  freshTest = mk pkgs ''
    start_all()
    wait_all()
    make_state()
    verify_state()
    record("${tag}")
    check("${tag}")
    machine.succeed("sync")
  '';

  newTop = (mk newPkgs "").config.nodes.machine.system.build.toplevel;
in
{
  fresh = freshTest;
  freshDriver = freshTest.driver;
  inherit newTop;
  switch = mk pkgs ''
    start_all()
    wait_all()
    make_state()
    verify_state()
    record("1-old")
    check("1-old")
    rc, out = machine.execute("${newTop}/bin/switch-to-configuration switch 2>&1")
    print(f"switch rc={rc}\n{out}")
    machine.succeed(f"cat > /tmp/switch.log <<'EOF'\nrc={rc}\n{out}\nEOF")
    machine.copy_from_machine("/tmp/switch.log", "")
    assert rc == 0, "switch-to-configuration failed"
    machine.succeed("podman --version | grep -q 'version 6'")
    wait_all()
    verify_state()
    record("2-switched")
    check("2-switched")
    machine.shutdown()
    machine.start()
    wait_all()
    verify_state()
    record("3-rollback-reboot")
    check("3-rollback-reboot")
  '';
}
