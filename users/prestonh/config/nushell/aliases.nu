# Root-neovim with user config
def nvims [file?: string] {
    sudo $"XDG_CONFIG_HOME=(if ($env.XDG_CONFIG_HOME? | is-empty) { 
        $"($env.HOME)/.config" 
    } else { 
        $env.XDG_CONFIG_HOME 
    })" nvim $file
}

# Root-git with user config
def gits [...spans] {
    sudo git -c include.path=$"(
        if ($env.XDG_CONFIG_HOME? | is-empty) { 
            $'($env.HOME)/.config' 
        } else { 
            $env.XDG_CONFIG_HOME 
        })/git/config" -c include.path=$"($env.HOME)/.gitconfig" ...$spans
}

