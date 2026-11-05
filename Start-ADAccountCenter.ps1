#requires -version 5.1
# Starts AD Account Center as the admin account named in config.json.
# runas.exe asks for that account's password in its own Windows prompt,
# so neither this launcher nor the app ever sees or stores the password.

$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$admin = ([string]$config.AdminAccount).Trim()
if (-not $admin) {
    Write-Error 'Set AdminAccount in config.json first.'
    exit 1
}

$app = Join-Path $PSScriptRoot 'ADAccountCenter.ps1'
$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $app + '\"'

Start-Process -FilePath 'runas.exe' -ArgumentList ('/user:' + $admin + ' "' + $command + '"')
