let external_completer = {|spans|
  let carapace_completer = {|spans|
    carapace $spans.0 nushell ...$spans
    | from json
    | if ($in | default [] | where value == $"($spans | last)ERR" | is-empty) {
      $in
    } else { null }
  }

  let zoxide_completer = {|spans|
    $spans | skip 1 | zoxide query -l $in | lines | where {|x| $x != $env.PWD}
  }

  # Handle aliases/command expansions
  let expanded_alias = scope aliases
    | where name == $spans.0
    | get -o 0.expansion

  let spans = if $expanded_alias != null {
    let alias_parts = ($expanded_alias | split row ' ')
    $alias_parts | append ($spans | slice 1..)
  } else {
    $spans
  }

  match $spans.0 {
    __zoxide_z | __zoxide_zi => $zoxide_completer,
    nvims => { |s| do $carapace_completer ($s | update 0 "nvim") },
    gits => { |s| do $carapace_completer ($s | update 0 "git") },
    _ => $carapace_completer
  } | do $in $spans
}

$env.config.completions.external = {
  enable: true,
  completer: $external_completer
}

