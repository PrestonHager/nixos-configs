# Phase 3 response stubs (manual approval required)

These scripts are **not** wired to Grafana webhooks yet. Run manually after triage.

| Script | Purpose |
|--------|---------|
| `block-ip-technitium.sh` | Add WAN source IP to Technitium blocklist zone (requires `TECHNITIUM_API_TOKEN` in sops) |
| `block-ip-nftables.sh` | Drop inbound traffic from IP on ace bond0 (temporary; lost on reboot unless persisted) |
| `port-shutdown-playbook.md` | Operator steps for Astraquasar interface shutdown |

Guardrails (from `docs/security-ids-plan.md`):

- WAN sources only for automated DNS blocks initially
- Whitelist operator IPs (`192.168.5.0/24` is trusted in fail2ban)
- Document every block in the private change log

See test cases **TC-3.1** through **TC-3.4** in `docs/security-ids-test-cases.md`.
