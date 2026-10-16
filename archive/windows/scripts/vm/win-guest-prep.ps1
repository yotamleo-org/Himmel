# win-guest-prep.ps1 - adopter-baseline PATH prep for the win11 test VM.
#
# Run INSIDE the guest, once, on a clean-install guest that already has
# Git for Windows, Python 3.12 and jq (winget, user scope; see docs/setup/vms.md).
# It makes the three tools himmelctl's preflight probes by PATH resolvable:
#   - bash:    Git for Windows puts only ...\Git\cmd on PATH; himmelctl wants bash.
#   - python3: python.org Python installs python.exe only; the python3 name on a
#              stock Windows is the Microsoft Store stub (on PATH, prints nothing).
# Idempotent. Changes the USER path only (no elevation needed).
$ErrorActionPreference = 'Stop'

$gitBin = 'C:\Program Files\Git\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $gitBin) {
    [Environment]::SetEnvironmentVariable('Path', "$gitBin;$userPath", 'User')
    Write-Output "added $gitBin to the user PATH"
}

$py = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312'
if (-not (Test-Path (Join-Path $py 'python.exe'))) { throw "no python.exe under $py" }
if (-not (Test-Path (Join-Path $py 'python3.exe'))) {
    Copy-Item (Join-Path $py 'python.exe') (Join-Path $py 'python3.exe')
    Write-Output "created $py\python3.exe"
}
