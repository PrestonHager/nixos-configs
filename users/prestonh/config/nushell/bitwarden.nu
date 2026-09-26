# Bitwarden CLI helpers for Vaultwarden SSH keys (astracap / astraquasar).
# Requires: bw login (once), then bw-unlock-ssh before ssh to Cisco hosts.

def bw-unlock-ssh [] {
  $env.BW_SESSION = (bw unlock --raw | complete | get stdout | str trim)
  let sock = (
    bash -c 'eval "$(bw ssh-agent)" && echo "$SSH_AUTH_SOCK"'
    | complete
    | get stdout
    | str trim
  )
  $env.SSH_AUTH_SOCK = $sock
  print $"Bitwarden SSH agent ready ($sock)"
}
