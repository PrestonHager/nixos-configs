<?php
// Applies Coolify roles from the identity provider to Coolify's root team (id 0).
// Input: COOLIFY_ROLE_MAP env, a JSON object keyed by lowercased email whose
// values are either "admin"|"member" or {"role": "admin"|"member", "name": "..."}
// (keycloak-role-sync.mjs writes the second form).
//
// With COOLIFY_CREATE_USERS=1, a mapped email without a Coolify account gets
// one (random password, root team only, no personal team), so OIDC logins
// link to it by verified email while Coolify's own self-registration stays
// off: only members of the Keycloak coolify_* groups can sign in.
//
// The root owner (user 0) is never changed. Users without a role are removed
// from the root team; their account and any personal team remain.
//
// An empty map while the team still has non-owner members is refused: it is
// far more likely to be a broken group query than every role being revoked
// at once. Set COOLIFY_ALLOW_EMPTY_ROLE_MAP=1 to apply it anyway.
// Errors are thrown; run.php turns them into a non-zero exit.
use App\Models\Team;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

$raw = getenv('COOLIFY_ROLE_MAP');
if ($raw === false || trim($raw) === '') {
    throw new RuntimeException('COOLIFY_ROLE_MAP is not set');
}
$input = json_decode($raw, true, flags: JSON_THROW_ON_ERROR);
if (! is_array($input) || ($input !== [] && array_is_list($input))) {
    throw new RuntimeException('COOLIFY_ROLE_MAP must be a JSON object');
}
$map = [];
$names = [];
foreach ($input as $email => $entry) {
    $email = strtolower(trim((string) $email));
    $role = is_array($entry) ? ($entry['role'] ?? null) : $entry;
    if (! in_array($role, ['admin', 'member'], true)) {
        throw new RuntimeException("COOLIFY_ROLE_MAP: invalid role for {$email}: " . var_export($role, true));
    }
    if (! filter_var($email, FILTER_VALIDATE_EMAIL)) {
        throw new RuntimeException('COOLIFY_ROLE_MAP: invalid email ' . var_export($email, true));
    }
    $map[$email] = $role;
    $names[$email] = is_array($entry) && filled($entry['name'] ?? null) ? (string) $entry['name'] : $email;
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
            . 'because the role map is empty; set COOLIFY_ALLOW_EMPTY_ROLE_MAP=1 if that is intended'
        );
    }
}

$changes = [];

if (getenv('COOLIFY_CREATE_USERS') === '1') {
    $existing = User::all()->map(fn (User $u) => strtolower(trim($u->email)))->all();
    foreach ($map as $email => $role) {
        if (in_array($email, $existing, true)) {
            continue;
        }
        // Like Coolify's own createRootTeamOnlyUser (OIDC auto_join_root_team):
        // no personal team, the root team membership is the account's team.
        DB::transaction(function () use ($team, $email, $role, $names) {
            $user = User::withoutEvents(fn () => User::create([
                'name' => $names[$email],
                'email' => $email,
                'password' => Hash::make(Str::random(64)),
            ]));
            $team->members()->attach($user->id, ['role' => $role]);
        });
        $changes[] = "created {$email} as {$role}";
    }
}

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
