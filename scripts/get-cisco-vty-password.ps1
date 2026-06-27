# Load Virtual terminal password from Vaultwarden Astracap item (never prints secret).
param(
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
$item = bw get item 38fa259d-4474-4641-b751-d3628dc13338 2>&1 | ConvertFrom-Json
$vty = $null
foreach ($line in ($item.notes -split "`r?`n")) {
  if ($line -match '(?i)virtual\s+terminal\s+password\s*[:=]\s*(.+)') { $vty = $matches[1].Trim() }
}
Remove-Item Env:BW_SESSION -ErrorAction SilentlyContinue
if ($vty) { return $vty }
throw 'No virtual terminal password found in Astracap Router Info vault item'
