# Load Cisco enable password from Vaultwarden (never prints secret).
param(
  [string]$Search = "Astracap",
  [switch]$PreferSecret
)

$env:Path = "C:\Users\prest\AppData\Roaming\npm;" + $env:Path
Get-Content "$env:USERPROFILE\.cursor\warden-mcp.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
    Set-Item -Path "env:$($matches[1])" -Value $matches[2]
  }
}
if (-not $env:BW_SESSION) {
  $env:BW_SESSION = (bw unlock --passwordenv BW_PASSWORD --raw 2>&1 | Select-Object -Last 1)
}

$items = @(bw list items --search $Search 2>&1 | ConvertFrom-Json)
if ($items.Count -eq 0) {
  Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
  throw "No vault items matched search: $Search"
}

$item = if ($items.Count -eq 1) { $items[0] } else {
  ($items | Where-Object { $_.name -match 'Astracap|Quasar|switch' } | Select-Object -First 1)
}
if (-not $item) { $item = $items[0] }

$full = bw get item $item.id 2>&1 | ConvertFrom-Json
$secret = $null
$password = $null
foreach ($line in ($full.notes -split "`r?`n")) {
  if ($line -match '(?i)enable\s+secret\s*[:=]\s*(.+)') { $secret = $matches[1].Trim() }
  if ($line -match '(?i)enable\s+password\s*[:=]\s*(.+)') { $password = $matches[1].Trim() }
}
Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
if ($PreferSecret -and $secret) { return $secret }
if ($secret) { return $secret }
if ($password) { return $password }
throw "No enable secret/password found in vault item: $($full.name)"
