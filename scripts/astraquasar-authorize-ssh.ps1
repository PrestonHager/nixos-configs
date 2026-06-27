# Authorize SSH pubkey on Astraquasar switch via serial (COM6).
param(
  [string]$SerialPort = "COM6",
  [string]$PubKey = "$env:USERPROFILE\.ssh\id_rsa_astracap.pub",
  [string]$Username = "admin"
)

$sec = Read-Host "Astraquasar enable password" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
  $env:CISCO_ENABLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$repo = Split-Path $PSScriptRoot -Parent
$env:CISCO_SERIAL_PORT = $SerialPort
$env:CISCO_SSH_USER = $Username
python "$repo\scripts\cisco-authorize-ssh.py" --port $SerialPort --pubkey $PubKey --username $Username
$exit = $LASTEXITCODE
Remove-Item Env:CISCO_ENABLE_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:CISCO_SERIAL_PORT -ErrorAction SilentlyContinue
Remove-Item Env:CISCO_SSH_USER -ErrorAction SilentlyContinue
exit $exit
