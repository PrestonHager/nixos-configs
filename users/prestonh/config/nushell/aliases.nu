def user-config-home [] {
    if ($env.XDG_CONFIG_HOME? | is-empty) {
        $"($env.HOME)/.config"
    } else {
        $env.XDG_CONFIG_HOME
    }
}

# Carapace completions for a wrapper, as if it were `cmd`. Custom commands
# never reach the external completer, so the wrappers declare these.
def complete-as [cmd: string, place: record] {
    carapace $cmd nushell $cmd ...($place.command | skip 1) | from json
}
def "nu-complete nvims" [place] { complete-as nvim $place }
def "nu-complete gits" [place] { complete-as git $place }

# Root-neovim with user config; all arguments and flags go to nvim
def --wrapped nvims [...args: string@"nu-complete nvims"] {
    sudo $"XDG_CONFIG_HOME=(user-config-home)" nvim ...$args
}

# Root-git with user config; all arguments and flags go to git.
# SSH_AUTH_SOCK is kept so root can sign with the user's agent key; a host
# root identity (/etc/git/root-identity, see nixos/ace-git-identity.nix) is
# included last so its signing key wins in the repos it covers.
def --wrapped gits [...args: string@"nu-complete gits"] {
    (sudo --preserve-env=SSH_AUTH_SOCK git
        -c $"include.path=(user-config-home)/git/config"
        -c $"include.path=($env.HOME)/.gitconfig"
        -c include.path=/etc/git/root-identity
        ...$args)
}
