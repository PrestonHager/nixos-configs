# Sync Git SSH signing private key from Vaultwarden → ~/.ssh/git_signing_ed25519.
# Vault item: git-signing-ed25519 (SSH key). Never prints private key material.
#
# Usage (PowerShell):
#   . .\scripts\sync-git-signing-key.ps1
param(
  [string]$ItemName = $(if ($env:GIT_SIGNING_BW_ITEM) { $env:GIT_SIGNING_BW_ITEM } else { 'git-signing-ed25519' }),
  [string]$Dest = $(if ($env:GIT_SIGNING_KEY_PATH) { $env:GIT_SIGNING_KEY_PATH } else { Join-Path $env:USERPROFILE '.ssh\git_signing_ed25519' }),
  [string]$Server = $(if ($env:BW_SERVER) { $env:BW_SERVER } else { 'https://vault.prestonhager.com' })
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
  throw 'bitwarden-cli (bw) not found on PATH'
}

$current = (bw config server 2>$null)
if ($current -ne $Server) {
  bw config server $Server | Out-Null
}

$status = (bw status | ConvertFrom-Json).status
if ($status -eq 'unauthenticated') {
  throw 'not logged in; run: bw login'
}
if ($status -eq 'locked' -and -not $env:BW_SESSION) {
  # Prefer password from env when present (e.g. automation); otherwise interactive unlock.
  if ($env:BW_PASSWORD) {
    $env:BW_SESSION = (bw unlock --passwordenv BW_PASSWORD --raw)
  } else {
    $env:BW_SESSION = (bw unlock --raw)
  }
}

bw sync | Out-Null

$items = bw list items --search $ItemName | ConvertFrom-Json
$item = $items | Where-Object { $_.name -eq $ItemName } | Select-Object -First 1
if (-not $item) {
  throw "vault item '$ItemName' not found"
}

$full = bw get item $item.id | ConvertFrom-Json
$priv = $full.sshKey.privateKey
$pub = $full.sshKey.publicKey
if (-not $priv) {
  throw "missing privateKey on SSH key item '$ItemName'"
}

$sshDir = Split-Path -Parent $Dest
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
[System.IO.File]::WriteAllText($Dest, ($priv.TrimEnd() + "`n"))
if ($pub) {
  [System.IO.File]::WriteAllText("$Dest.pub", ($pub.TrimEnd() + "`n"))
}

icacls $Dest /inheritance:r | Out-Null
icacls $Dest /grant:r "$($env:USERNAME):(R)" | Out-Null

$fp = $null
if (Test-Path "$Dest.pub") {
  $fp = ((ssh-keygen -lf "$Dest.pub") -split '\s+')[1]
}

Write-Host "Synced Git signing key to $Dest"
if ($fp) {
  Write-Host "Fingerprint: $fp"
}
