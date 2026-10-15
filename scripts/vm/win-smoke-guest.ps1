# win-smoke-guest.ps1 -- guest half of the win11 adopt/uninstall smoke cell.
#
# Runs INSIDE the win11 guest under Windows PowerShell 5.1 (the stock shell an
# adopter has). ASCII only on purpose: 5.1 reads a BOM-less file as ANSI
# Driven by scripts/vm/win-smoke-cell.sh; prints the evidence
# contract of the Linux matrix: per step `CELL | CMD | LAST | rc`, then
# `CHECK <PASS|FAIL> <name>` lines and one `VERDICT`.
#
# Cell win11-adopt-uninstall-project:
#   1. fresh clone of the git bundle at <Tag>, checked out detached
#   2. fresh project dir, git init
#   3. himmelctl install --scope project  (non-interactive adopter-project profile)
#   4. himmelctl uninstall --yes
param(
    [Parameter(Mandatory = $true)][string]$Bundle,
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Work = (Join-Path $env:USERPROFILE 'cell')
)
$ErrorActionPreference = 'Continue'
# Native output is OEM-decoded by default; guarded because a
# guestcontrol run has no console handle on some images.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { Write-Warning 'OutputEncoding not set; native output may be OEM-decoded' }
$Cell = 'win11-adopt-uninstall-project'
$script:Fail = 0

function Step([string]$Name, [string]$Cmd, [string]$Dir) {
    # cmd /c so native stderr never becomes a PowerShell error record under 5.1.
    $full = 'cd /d "' + $Dir + '" && ' + $Cmd + ' 2>&1'
    $out = & cmd.exe /c $full
    $rc = $LASTEXITCODE
    $last = ($out | Select-Object -Last 3) -join ' / '
    Write-Output ("CELL {0} | STEP {1} | CMD {2} | LAST {3} | rc={4}" -f $Cell, $Name, $Cmd, $last, $rc)
    # Not `return`: pipeline output would mix with the CELL line (PS 5.1).
    $script:Rc = $rc
}

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Output "CHECK PASS $Name" }
    else { Write-Output "CHECK FAIL $Name -- $Detail"; $script:Fail++ }
}

$himmel = Join-Path $Work 'himmel'
$proj = Join-Path $Work 'proj'
$ctl = Join-Path $himmel 'scripts\himmelctl\bin.js'
$projSettings = Join-Path $proj '.claude\settings.json'
$launcher = Join-Path $env:USERPROFILE '.local\bin\himmelctl.cmd'

if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Path $Work | Out-Null
Copy-Item $Bundle (Join-Path $Work 'src.bundle')

Step 'clone' 'git clone src.bundle himmel' $Work
Check 'clone-rc0' ($rc -eq 0) "rc=$rc"
Step 'checkout' ("git -C himmel checkout " + $Tag) $Work
Check 'checkout-rc0' ($rc -eq 0) "rc=$rc"
$desc = (& git -C $himmel describe --tags --exact-match 2>$null)
Check 'tag-exact' ($desc -eq $Tag) "describe=$desc want=$Tag"
Check 'clone-has-git-dir' (Test-Path (Join-Path $himmel '.git')) 'no .git in the clone'

New-Item -ItemType Directory -Path $proj | Out-Null
Step 'project-init' 'git init -q' $proj
Check 'project-init-rc0' ($rc -eq 0) "rc=$rc"

# --- install ---------------------------------------------------------------
Step 'install' ('node "' + $ctl + '" install --scope project') $proj
Check 'install-rc0' ($rc -eq 0) "rc=$rc"
Check 'install-project-settings-exist' (Test-Path $projSettings) "missing $projSettings"
$hasRepo = $false
if (Test-Path $projSettings) { $hasRepo = [bool](Select-String -Path $projSettings -Pattern 'HIMMEL_REPO' -Quiet) }
Check 'install-project-settings-wired' $hasRepo 'no HIMMEL_REPO in the project settings'
Check 'install-launcher-written' (Test-Path $launcher) "missing $launcher"

# --- uninstall -------------------------------------------------------------
Step 'uninstall' ('node "' + $ctl + '" uninstall --yes') $proj
Check 'uninstall-rc0' ($rc -eq 0) "rc=$rc"
$left = $false
if (Test-Path $projSettings) { $left = [bool](Select-String -Path $projSettings -Pattern 'HIMMEL_REPO' -Quiet) }
# Known Windows gap uninstall.ps1 never unwires project settings (Linux does).
# Reported as XFAIL, not hidden; it turns into CHECK PASS once the twin lands, and the
# marker below must then be removed.
if ($left) { Write-Output 'CHECK XFAIL uninstall-project-settings-unwired -- HIMMEL_REPO still in the project settings (known gap HIMMEL-5427)' }
else { Write-Output 'CHECK PASS uninstall-project-settings-unwired' }
Check 'uninstall-launcher-removed' (-not (Test-Path $launcher)) "still present: $launcher"

if ($script:Fail -eq 0) { Write-Output "VERDICT PASS $Cell tag=$Tag"; exit 0 }
Write-Output ("VERDICT FAIL {0} tag={1} failed={2}" -f $Cell, $Tag, $script:Fail)
exit 1
