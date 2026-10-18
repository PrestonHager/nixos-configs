<?php
// Applies Zitadel Coolify roles to Coolify's root team (id 0).
// Input: COOLIFY_ROLE_MAP env, JSON {email: "admin"|"member"}.
// The root owner (user 0) is never changed. Users without a Coolify grant
// are removed from the root team; their personal team and account remain.
//
// An empty map while the team still has non-owner members is refused: it is
// far more likely to be a broken Zitadel query than every grant being
// revoked at once. Set COOLIFY_ALLOW_EMPTY_ROLE_MAP=1 to apply it anyway.
// Errors are thrown; run.php turns them into a non-zero exit.
use App\Models\Team;
use App\Models\User;

$raw = getenv('COOLIFY_ROLE_MAP');
if ($raw === false || trim($raw) === '') {
    throw new RuntimeException('COOLIFY_ROLE_MAP is not set');
}
$map = json_decode($raw, true, flags: JSON_THROW_ON_ERROR);
if (! is_array($map) || ($map !== [] && array_is_list($map))) {
    throw new RuntimeException('COOLIFY_ROLE_MAP must be a JSON object');
}
foreach ($map as $email => $role) {
    if (! in_array($role, ['admin', 'member'], true)) {
        throw new RuntimeException("COOLIFY_ROLE_MAP: invalid role for {$email}: " . var_export($role, true));
    }
}

$team = Team::findOrFail(0);

if ($map === [] && getenv('COOLIFY_ALLOW_EMPTY_ROLE_MAP') !== '1') {
    $others = $team->members()
        ->where('users.id', '!=', 0)
        ->wherePivot('role', '!=', 'owner')
        ->pluck('users.email')
        ->all();
    if ($others) {
        throw new RuntimeException(
            'refusing to remove ' . count($others) . ' root team member(s) (' . implode(', ', $others) . ') '
            . 'because the Zitadel role map is empty; set COOLIFY_ALLOW_EMPTY_ROLE_MAP=1 if that is intended'
        );
    }
}

$changes = [];

foreach (User::where('id', '!=', 0)->get() as $user) {
    $email = strtolower(trim($user->email));
    $want = $map[$email] ?? null;
    $member = $team->members()->where('users.id', $user->id)->first();
    $have = $member?->pivot->role;

    if ($want === null) {
        if ($member && $have !== 'owner') {
            $team->members()->detach($user->id);
            $changes[] = "removed {$email} from root team";
        }
        continue;
    }
    if (! $member) {
        $team->members()->attach($user->id, ['role' => $want]);
        $changes[] = "added {$email} as {$want}";
    } elseif ($have !== $want && $have !== 'owner') {
        $team->members()->updateExistingPivot($user->id, ['role' => $want]);
        $changes[] = "{$email}: {$have} -> {$want}";
    }
}

echo $changes ? implode(PHP_EOL, $changes) . PHP_EOL : 'no changes' . PHP_EOL;
