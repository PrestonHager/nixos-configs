<?php

namespace Pterodactyl\Addons\Minecraft;

use Illuminate\Validation\ValidationException;

/**
 * server.properties parsing/editing that keeps comments and key order, plus
 * the typed fields the form exposes. Unknown keys round-trip untouched.
 */
class ServerProperties
{
    /**
     * key => [type, options|range]. Types: bool, int, enum, string.
     */
    public const FIELDS = [
        'motd' => ['string', null],
        'gamemode' => ['enum', ['survival', 'creative', 'adventure', 'spectator']],
        'difficulty' => ['enum', ['peaceful', 'easy', 'normal', 'hard']],
        'hardcore' => ['bool', null],
        'pvp' => ['bool', null],
        'max-players' => ['int', [1, 10000]],
        'view-distance' => ['int', [2, 32]],
        'simulation-distance' => ['int', [2, 32]],
        'spawn-protection' => ['int', [0, 1000]],
        'online-mode' => ['bool', null],
        'white-list' => ['bool', null],
        'enforce-whitelist' => ['bool', null],
        'allow-flight' => ['bool', null],
        'allow-nether' => ['bool', null],
        'spawn-monsters' => ['bool', null],
        'generate-structures' => ['bool', null],
        'level-name' => ['string', null],
        'level-seed' => ['string', null],
        'level-type' => ['string', null],
        'enable-command-block' => ['bool', null],
        'enable-query' => ['bool', null],
        'enable-rcon' => ['bool', null],
        'force-gamemode' => ['bool', null],
        'player-idle-timeout' => ['int', [0, 100000]],
        'max-world-size' => ['int', [1, 29999984]],
        'resource-pack' => ['string', null],
        'require-resource-pack' => ['bool', null],
    ];

    /**
     * Keys owned by the egg/allocation; edits here would be undone on start.
     */
    public const LOCKED = ['server-port', 'server-ip', 'query.port', 'rcon.port', 'rcon.password'];

    /**
     * @return array<string, string>
     */
    public static function parse(string $content): array
    {
        $values = [];
        foreach (preg_split('/\r?\n/', $content) as $line) {
            if ($line === '' || $line[0] === '#' || $line[0] === '!' || !str_contains($line, '=')) {
                continue;
            }

            [$key, $value] = explode('=', $line, 2);
            $values[trim($key)] = $value;
        }

        return $values;
    }

    /**
     * Apply changes to the original file text.
     *
     * @param array<string, scalar|null> $changes
     */
    public static function apply(string $content, array $changes): string
    {
        $changes = self::validate($changes);
        $lines = $content === '' ? [] : preg_split('/\r?\n/', rtrim($content, "\r\n"));

        foreach ($lines as $i => $line) {
            if ($line === '' || $line[0] === '#' || $line[0] === '!' || !str_contains($line, '=')) {
                continue;
            }

            $key = trim(explode('=', $line, 2)[0]);
            if (array_key_exists($key, $changes)) {
                $lines[$i] = $key . '=' . $changes[$key];
                unset($changes[$key]);
            }
        }

        foreach ($changes as $key => $value) {
            $lines[] = $key . '=' . $value;
        }

        return implode("\n", $lines) . "\n";
    }

    /**
     * @param array<string, scalar|null> $changes
     *
     * @return array<string, string>
     */
    public static function validate(array $changes): array
    {
        $errors = [];
        $clean = [];

        foreach ($changes as $key => $value) {
            $key = (string) $key;
            $value = is_bool($value) ? ($value ? 'true' : 'false') : (string) $value;

            if (!preg_match('/^[a-z0-9][a-z0-9.\-_]*$/i', $key)) {
                $errors[$key] = 'Invalid property name.';
                continue;
            }
            if (in_array($key, self::LOCKED, true)) {
                $errors[$key] = 'Managed by the panel (allocation/startup); not editable here.';
                continue;
            }
            if (str_contains($value, "\n") || str_contains($value, "\r")) {
                $errors[$key] = 'Values cannot contain line breaks.';
                continue;
            }

            [$type, $rule] = self::FIELDS[$key] ?? ['string', null];
            $ok = match ($type) {
                'bool' => in_array($value, ['true', 'false'], true),
                'int' => preg_match('/^-?\d+$/', $value) && (int) $value >= $rule[0] && (int) $value <= $rule[1],
                'enum' => in_array($value, $rule, true),
                default => true,
            };

            if (!$ok) {
                $errors[$key] = match ($type) {
                    'bool' => 'Must be true or false.',
                    'int' => "Must be a whole number from {$rule[0]} to {$rule[1]}.",
                    'enum' => 'Must be one of: ' . implode(', ', $rule) . '.',
                    default => 'Invalid value.',
                };
                continue;
            }

            $clean[$key] = $value;
        }

        if ($errors !== []) {
            throw ValidationException::withMessages(array_map(fn ($m) => [$m], $errors));
        }

        return $clean;
    }
}
