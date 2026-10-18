<?php
// Runs the script named by COOLIFY_TINKER_SCRIPT inside Coolify's booted app
// and turns any uncaught exception into exit status 1.
//
// `php artisan tinker <file>` and `tinker --execute=...` (laravel/tinker
// 2.11, psysh 0.12) both print an exception and still exit 0, so a failure
// would look like success to systemd. A plain exit() in a required file is
// not rewritten by psysh and ends the process with that status.
$script = getenv('COOLIFY_TINKER_SCRIPT');
try {
    if (! $script || ! is_file($script)) {
        throw new RuntimeException('COOLIFY_TINKER_SCRIPT is unset or not a file: ' . var_export($script, true));
    }
    require $script;
} catch (Throwable $e) {
    fwrite(STDERR, basename((string) $script) . ': ' . get_class($e) . ': ' . $e->getMessage() . PHP_EOL);
    exit(1);
}
