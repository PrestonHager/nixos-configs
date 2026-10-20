<?php
// Sends Coolify's mail (password resets, invitations, notifications) through
// the iCloud+ SMTP account that Nextcloud, Grafana and Zitadel already use.
// The password comes from SMTP_PASSWORD in the nextcloud-environment sops
// secret, passed with `podman exec --env-file`. Idempotent: only saves what
// differs.
//
// Instance settings hold the transport. The root team's email notifications
// use them (use_instance_email_settings); with no recipients set there,
// Coolify mails the team's members.
use App\Models\InstanceSettings;
use App\Models\Team;

$password = getenv('SMTP_PASSWORD');
if (! $password) {
    throw new RuntimeException('SMTP_PASSWORD missing');
}

$wanted = [
    'smtp_enabled' => true,
    'smtp_host' => 'smtp.mail.me.com',
    'smtp_port' => 587,
    'smtp_encryption' => 'starttls',
    'smtp_username' => 'prestonhager@icloud.com',
    'smtp_password' => $password,
    'smtp_from_address' => 'admin@prestonhager.com',
    'smtp_from_name' => 'Coolify',
    'smtp_timeout' => 30,
    'resend_enabled' => false,
];

$changes = [];

$settings = InstanceSettings::get();
foreach ($wanted as $key => $value) {
    if ($settings->{$key} !== $value) {
        $settings->{$key} = $value;
        $changes[] = $key === 'smtp_password' ? 'smtp_password=(updated)' : "{$key}=" . var_export($value, true);
    }
}
if ($settings->isDirty()) {
    $settings->save();
}

$team = Team::find(0);
if (! $team) {
    throw new RuntimeException('root team 0 not found');
}
$email = $team->emailNotificationSettings()->firstOrCreate(['team_id' => 0]);
if (! $email->use_instance_email_settings) {
    $email->use_instance_email_settings = true;
    $email->save();
    $changes[] = 'root team email notifications use instance SMTP';
}

echo $changes ? implode(PHP_EOL, $changes) . PHP_EOL : 'no changes' . PHP_EOL;
