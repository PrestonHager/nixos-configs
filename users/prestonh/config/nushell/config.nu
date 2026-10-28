# Nushell config (loaded after env.nu).
# Only overrides go here; Nushell fills in defaults for everything else.
# Full reference: `config nu --doc | nu-highlight | less -R`

$env.config.show_banner = false

# Keep using ~/.config/nushell/history.txt
$env.config.history.file_format = "plaintext"
$env.config.history.max_size = 100_000
$env.config.history.sync_on_enter = true

$env.config.edit_mode = "vi"
$env.config.cursor_shape.emacs = "line"
$env.config.cursor_shape.vi_insert = "block"
$env.config.cursor_shape.vi_normal = "underscore"
$env.config.buffer_editor = "nvim"

$env.config.footer_mode = 25
$env.config.filesize.unit = "metric"

$env.config.completions.case_sensitive = false
$env.config.completions.quick = true
$env.config.completions.partial = true
$env.config.completions.algorithm = "prefix"
$env.config.completions.use_ls_colors = true

# Carapace/zoxide external completer
source ~/.config/nushell/completions.nu
