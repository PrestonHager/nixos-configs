$env.PATH = ($env.PATH | split row (char esep) | prepend "/home/prestonh/.config/carapace/bin")

def --env get-env [name] { $env | get $name }
def --env set-env [name, value] { load-env { $name: $value } }
def --env unset-env [name] { hide-env $name }

let external_completer = {|spans|
  let carapace_completer = {|spans|
    carapace $spans.0 nushell ...$spans
    | from json
    | if ($in | default [] | where value == $"($spans | last)ERR" | is-empty) { $in } else { null }
  }
  let zoxide_completer = {|spans|
    $spans | skip 1 | zoxide query -l $in | lines | where {|x| $x != $env.PWD}
  }

  let expanded_alias = scope aliases | where name == $spans.0 | get -o 0 | get -o expansion
  let spans = if $expanded_alias != null  {
    $spans | skip 1 | prepend ($expanded_alias | split row " " | take 1)
  } else {
    $spans
  }

  match $spans.0 {
    __zoxide_z | __zoxide_zi => $zoxide_completer,
    _ => $carapace_completer
  } | do $in $spans
}

#let carapace_completer = {|spans|
#  # if the current command is an alias, get it's expansion
#  let expanded_alias = (scope aliases | where name == $spans.0 | get -o 0 | get -o expansion)
#
#  # overwrite
#  let spans = (if $expanded_alias != null  {
#    # put the first word of the expanded alias first in the span
#    $spans | skip 1 | prepend ($expanded_alias | split row " " | take 1)
#  } else {
#    $spans | skip 1 | prepend ($spans.0)
#  })
#
#  carapace $spans.0 nushell ...$spans
#  | from json
#}

mut current = (($env | default {} config).config | default {} completions)
$current.completions = ($current.completions | default {} external)
$current.completions.external = ($current.completions.external
| default true enable
| default $external_completer completer)

$env.config = $current
    
