#!/usr/bin/env bash
# Runs the podman CLI invocations ace's scripts use and connectivity probes.
# Each probe prints "### <label>", its output, and "### rc=<n>".
set -u
run() { local label="$1"; shift; echo "### $label"; bash -c "$*" 2>&1 | head -60; echo "### rc=${PIPESTATUS[0]}"; }
w() { echo "podman exec $1 wget -q -O- -T 4 $2"; }

run version "podman --version; netavark --version 2>/dev/null || /run/current-system/sw/libexec/podman/netavark --version 2>/dev/null; uname -r"
run info "podman info --format '{{.Host.NetworkBackend}} {{.Store.GraphDriverName}} {{.Host.CgroupsVersion}} {{.Host.DatabaseBackend}}'"
run firewall_driver "podman info --format json | jq -r '.host.networkBackendInfo // {} | .package // empty' | head -1; ls /var/lib/containers/storage/ | tr '\n' ' '"
run ps_names "podman ps --format '{{.Names}}' | sort | tr '\n' ' '"
run ps_all "podman ps -a --format '{{.Names}} {{.Status}}' | sed -E 's/(Up|Exited)[^(]*/\\1 /' | sort"
run pod_ps "podman pod ps --format '{{.Name}} {{.Status}} {{.NumberOfContainers}}' | sort"
run infra_id_len "podman pod inspect zt-pod --format '{{.InfraContainerID}}' | tr -d '\n' | wc -c"
run infra_running "podman container inspect \$(podman pod inspect zt-pod --format '{{.InfraContainerID}}') --format '{{.State.Running}}'"
run infra_conmon_cgroup "cat /proc/\$(podman container inspect \$(podman pod inspect zt-pod --format '{{.InfraContainerID}}') --format '{{.State.ConmonPid}}')/cgroup"
run zt_hostadd "podman pod inspect zt-pod --format '{{range .InfraConfig.HostAdd}}{{.}} {{end}}'"
run gf_hostadd "podman pod inspect gf-pod --format '{{range .InfraConfig.HostAdd}}{{.}} {{end}}'"
run gf_ports_json "podman pod inspect gf-pod --format '{{json .InfraConfig.PortBindings}}'"
run gf_hostadd_json "podman pod inspect gf-pod --format '{{json .InfraConfig.HostAdd}}'"
run gf_dns_json "podman pod inspect gf-pod --format '{{json .InfraConfig.DNSServer}}'"
run pod_inspect_json_type "podman pod inspect gf-pod | jq -r 'type'"
run state_pid "podman inspect -f '{{.State.Pid}}' web1 | grep -cE '^[1-9][0-9]*$'"
run ps_filter_image "podman ps -a --filter 'name=^web1\$' --format '{{.Image}}'"
run inspect_imagename "podman inspect web1 --format '{{.ImageName}}'"
run inspect_image_len "podman inspect web1 --format '{{.Image}}' | tr -d '\n' | wc -c"
run image_env "podman image inspect localhost/tbox:1 --format '{{range .Config.Env}}{{println .}}{{end}}'"
run image_id_len "podman image inspect localhost/tbox:1 --format '{{.Id}}' | tr -d '\n' | wc -c"
run image_label "podman image inspect localhost/tbox:1 --format '{{index .Labels \"org.opencontainers.image.version\"}}'"
run backup_running "podman container inspect zt-db --format '{{.State.Running}}' | grep -q true && echo yes"
run tnet_inspect "podman network inspect tnet --format '{{.NetworkInterface}} {{range .Subnets}}{{.Subnet}}{{end}}'"
run ghr_inspect "podman network inspect ghr --format '{{.NetworkInterface}} {{range .Subnets}}{{.Subnet}}{{end}}'"
run net_options "for n in podman tnet ghr; do echo \$n \$(podman network inspect \$n --format '{{.Options}} dns={{.DNSEnabled}}'); done"
run default_net "podman network inspect podman --format '{{.NetworkInterface}} {{range .Subnets}}{{.Subnet}} {{.Gateway}}{{end}}'"
run health_app "podman inspect zt-app --format '{{.State.Health.Status}}'"
run health_db "podman inspect zt-db --format '{{.State.Health.Status}}'"
run health_none "podman inspect web1 --format '{{.State.Health.Status}}'"
run pg_isready "podman exec zt-db pg_isready -q -U postgres && echo ok"
run docker_compat "docker ps --format '{{.Names}}' | sort | head -2 | tr '\n' ' '"
run podman0_addr "ip -4 -o addr show podman0 | awk '{print \$4}'"
run tui "podman-tui version"
# Host -> published ports
run host_zt_9080 "curl -sf -m4 http://127.0.0.1:9080/"
run host_zt_9081_pg "curl -s -m3 -o /dev/null http://127.0.0.1:9081/; [ \$? -ne 7 ] && echo connected"
run host_gf_lo "curl -sf -m4 http://127.0.0.1:8082/"
run host_gf_gw "curl -sf -m4 http://10.88.0.1:8082/"
run host_web1_lo "curl -sf -m4 http://127.0.0.1:8181/"
run host_web2_any "curl -sf -m4 http://127.0.0.1:8182/"
LANIP=$(ip -4 -o addr show eth1 | awk "{print \$4}" | cut -d/ -f1)
TNETGW=$(podman network inspect tnet --format "{{range .Subnets}}{{.Gateway}}{{end}}")
run host_web2_lan "curl -sf -m4 http://$LANIP:8182/"
run host_def1_gw "curl -sf -m4 http://10.88.0.1:8190/"
# Pod internals
run pod_sibling_localhost "podman exec zt-app nc -z -w3 127.0.0.1 5432 && echo ok"
run pod_hosts_entry "podman exec zt-app grep -E 'zt.example|host.containers.internal' /etc/hosts | sort"
run gf_resolv "podman exec gf cat /etc/resolv.conf | grep nameserver"
# Custom network DNS (aardvark) and container-to-container
run dns_tnet_web1 "$(w tclient http://web1/)"
run dns_tnet_nslookup "podman exec tclient nslookup web2 | grep -A1 'Name:' | tail -1 | sed 's/[0-9.]*\$/<ip>/'"
run dns_tnet_external_name "podman exec tclient nslookup machine | grep -c Address"
# Host firewall on podman0 (nixos-fw) vs podman1
run c_podman0_to_host_9100 "$(w def1 http://10.88.0.1:9100/)"
run c_podman0_to_host_9999_blocked "$(w def1 http://10.88.0.1:9999/)"
run c_podman1_to_host_9100_blocked "$(w tclient http://$TNETGW:9100/)"
# Cross-network (netavark 2: strict isolation default)
DEF1=$(podman inspect def1 --format '{{.NetworkSettings.IPAddress}}')
WEB1=$(podman inspect web1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
run x_tnet_to_def1_direct "$(w tclient http://$DEF1/)"
run x_tnet_to_def1_published_gw "$(w tclient http://10.88.0.1:8190/)"
run x_podman0_to_web1_direct "$(w def1 http://$WEB1/)"
run x_podman0_to_web2_published_lan "$(w def1 http://$LANIP:8182/)"
run x_pod_to_web1_direct "$(w zt-app http://$WEB1/)"
# Runner network isolation
run ghr_to_def1_direct_blocked "$(w ghrc http://$DEF1/)"
run ghr_to_web1_direct_blocked "$(w ghrc http://$WEB1/)"
run ghr_to_host_9100_blocked "$(w ghrc http://10.250.250.1:9100/)"
run ghr_to_lan_blocked "$(w ghrc http://192.168.1.1:80/)"
# Firewall plumbing
run fw_iptables_netavark "iptables-save | grep -c -i netavark"
run fw_iptables_netavark_rules "iptables-save | grep -i netavark | grep -v '^:'"
run fw_nft_tables "nft list tables | sort | tr '\n' ' '"
run fw_dns_rules "iptables -S nixos-fw | grep -E 'dport 53' | sort"
run netavark_errors "journalctl -b --no-pager | grep -i -E 'netavark|aardvark' | grep -i -E 'error|fail' | tail -5"
true
