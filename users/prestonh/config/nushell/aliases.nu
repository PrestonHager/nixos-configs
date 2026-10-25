def user-config-home [] {
    if ($env.XDG_CONFIG_HOME? | is-empty) {
        $"($env.HOME)/.config"
    } else {
        $env.XDG_CONFIG_HOME
    }
}

# Root-neovim with user config; all arguments and flags go to nvim
def --wrapped nvims [...args] {
    sudo $"XDG_CONFIG_HOME=(user-config-home)" nvim ...$args
}

# Root-git with user config; all arguments and flags go to git.
# SSH_AUTH_SOCK is kept so root can sign with the user's agent key; a host
# root identity (/etc/git/root-identity, see nixos/ace-git-identity.nix) is
# included last so its signing key wins in the repos it covers.
def --wrapped gits [...args] {
    (sudo --preserve-env=SSH_AUTH_SOCK git
        -c $"include.path=(user-config-home)/git/config"
        -c $"include.path=($env.HOME)/.gitconfig"
        -c include.path=/etc/git/root-identity
        ...$args)
}
