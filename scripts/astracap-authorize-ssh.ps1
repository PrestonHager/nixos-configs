# Secure prompt for Astracap enable password, then authorize SSH pubkey via serial.
# Password is not echoed and is cleared from the environment after the run.
param(
  [string]$SerialPort = "COM6",
  [string]$PubKey = "$env:USERPROFILE\.ssh\id_rsa_astracap.pub"
)

$sec = Read-Host "Astracap enable password" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
  $env:ASTRACAP_ENABLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$repo = Split-Path $PSScriptRoot -Parent
python "$repo\scripts\astracap-authorize-ssh.py" --port $SerialPort --pubkey $PubKey
$exit = $LASTEXITCODE
Remove-Item Env:ASTRACAP_ENABLE_PASSWORD -ErrorAction SilentlyContinue
exit $exit
