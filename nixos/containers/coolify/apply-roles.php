<?php
// Applies Zitadel Coolify roles to Coolify's root team (id 0).
// Input: COOLIFY_ROLE_MAP env, JSON {email: "admin"|"member"}.
// The root owner (user 0) is never changed. Users without a Coolify grant
// are removed from the root team; their personal team and account remain.
use App\Models\Team;
use App\Models\User;

$map = json_decode(getenv('COOLIFY_ROLE_MAP') ?: '{}', true, flags: JSON_THROW_ON_ERROR);
$team = Team::findOrFail(0);
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

