# Usage: pwsh -File crystallize-note.ps1 <note_path> <transcript_path>
param(
    [string]$NotePath,
    [string]$TranscriptPath,
    [string]$RulesFile
)
$ErrorActionPreference = 'SilentlyContinue'

if (-not $NotePath) { exit 0 }

$rulesFile = if ($env:CRYSTALLIZE_RULES_FILE) { $env:CRYSTALLIZE_RULES_FILE } else { $RulesFile }
$refresh = ($env:CRYSTALLIZE_REFRESH -eq '1')

$env:CLAUDE_END_SESSION_WIKI = '0'
$env:HIMMEL_WHERE_ARE_WE = '0'

if ($env:CLAUDE_CONFIG_DIR) {
    try {
        $configuredClaudeDir = (Resolve-Path -LiteralPath $env:CLAUDE_CONFIG_DIR -ErrorAction Stop).Path
        $nativeClaudeDir = (Resolve-Path -LiteralPath (Join-Path $HOME '.claude') -ErrorAction Stop).Path
    } catch { exit 0 }
    if (-not [String]::Equals($configuredClaudeDir, $nativeClaudeDir, [StringComparison]::OrdinalIgnoreCase)) {
        [Console]::Error.WriteLine("crystallize-note: DEFERRED (not failed) - CLAUDE_CONFIG_DIR=$($env:CLAUDE_CONFIG_DIR) is not ~/.claude; the mechanical note is still written and stays crystallized: false; backfill-sessions.sh --reheal picks it up later once running on native auth.")
        exit 0
    }
}

$bin = $env:CRYSTALLIZE_CLAUDE_BIN
if (-not $bin) { $bin = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $bin) { exit 0 }

$maxC = if ($env:CRYSTALLIZE_MAX_CONCURRENCY) { [int]$env:CRYSTALLIZE_MAX_CONCURRENCY } else { 2 }
$pidDir = if ($env:CRYSTALLIZE_PID_DIR) { $env:CRYSTALLIZE_PID_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'himmel-crystallize' }
New-Item -ItemType Directory -Path $pidDir -Force | Out-Null
$live = 0
Get-ChildItem -Path $pidDir -Filter '*.pid' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($p -and (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) { $live++ }
    else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}
if ($live -ge $maxC) { exit 0 }
$myPid = Join-Path $pidDir "$PID.pid"
Set-Content -LiteralPath $myPid -Value $PID -ErrorAction SilentlyContinue
$settingsTmp = $null
$snapTmp = $null
try {
    # Retry-read: the live hook may have just written the note via the Obsidian
    # REST API, which flushes to disk asynchronously.
    $i = 0
    while (-not (Test-Path -LiteralPath $NotePath) -and $i -lt 3) { Start-Sleep -Seconds 1; $i++ }
    if (-not (Test-Path -LiteralPath $NotePath)) { exit 0 }

    if (-not $refresh -and (Select-String -LiteralPath $NotePath -Pattern '^crystallized: true$' -Quiet)) { exit 0 }

    if ($refresh) {
        $snapTmp = "$NotePath.snap.$PID"
        try { Copy-Item -LiteralPath $NotePath -Destination $snapTmp -Force -ErrorAction Stop }
        catch { $snapTmp = $null; exit 0 }
    }

    if ($refresh) {
        $prompt = @"
You are re-consolidating an already-synthesized Claude Code session note for an Obsidian vault.
Read the session transcript at: $TranscriptPath
Read the note at: $NotePath
This note was already synthesized. Re-read the transcript and the existing sections;
UPDATE/EXTEND the four sections below, preserving prior synthesis content that is
still correct — do not discard it:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop.

Optionally, ALSO append one more section after ## Follow-ups if the session
surfaced a genuine reusable lesson (a gotcha, decision, or fact worth
remembering beyond this session — skip the section entirely if there is no
genuine lesson):
- ## Lessons — a fenced code block labeled jsonl, one JSON object per line:
  {"id": "YYYY-MM-DD-<kebab-slug>", "claim": "<the lesson, 1-3 lines, self-contained>", "source": {"type": "session", "ref": "<this note's vault-relative path>#Lessons"}, "captured_at": "<UTC ISO-8601 now>", "captured_by": "end-session-wiki", "confidence": "<see below>", "scope": ["<see below>"], "status": "<see below>"}
  confidence is exactly one of: high (observed directly), medium (inferred from one occurrence), low (speculative).
  status is: active when confidence is high, unverified otherwise.
  scope is a list of one or more of ONLY these tags: guardrails, cr, lanes, jira, handover, telegram, vault, env-windows, env-macos, billing, harness.
This section is best-effort: a malformed line must never stop you from
finishing the required sections above. It is checked later by a lean-invoke
validation pass (scripts/lessons/validate-lesson.mjs --capture), not at capture time.
"@
    } else {
        $prompt = @"
You are crystallizing a Claude Code session note for an Obsidian vault.
Read the session transcript at: $TranscriptPath
Read the note at: $NotePath
Rewrite ONLY these sections of that note, in place, distilling the session:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop.

Optionally, ALSO append one more section after ## Follow-ups if the session
surfaced a genuine reusable lesson (a gotcha, decision, or fact worth
remembering beyond this session — skip the section entirely if there is no
genuine lesson):
- ## Lessons — a fenced code block labeled jsonl, one JSON object per line:
  {"id": "YYYY-MM-DD-<kebab-slug>", "claim": "<the lesson, 1-3 lines, self-contained>", "source": {"type": "session", "ref": "<this note's vault-relative path>#Lessons"}, "captured_at": "<UTC ISO-8601 now>", "captured_by": "end-session-wiki", "confidence": "<see below>", "scope": ["<see below>"], "status": "<see below>"}
  confidence is exactly one of: high (observed directly), medium (inferred from one occurrence), low (speculative).
  status is: active when confidence is high, unverified otherwise.
  scope is a list of one or more of ONLY these tags: guardrails, cr, lanes, jira, handover, telegram, vault, env-windows, env-macos, billing, harness.
This section is best-effort: a malformed line must never stop you from
finishing the required sections above. It is checked later by a lean-invoke
validation pass (scripts/lessons/validate-lesson.mjs --capture), not at capture time.
"@
    }

    if ($rulesFile -and (Test-Path -LiteralPath $rulesFile)) {
        $rulesContent = (Get-Content -LiteralPath $rulesFile -Raw)
        if (-not [string]::IsNullOrWhiteSpace($rulesContent)) {
            $prompt = $prompt + @"

Additionally apply these operator rules when synthesizing:
--- begin operator rules ---
$rulesContent
--- end operator rules ---
"@
        }
    }

    $himmelRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $hookPath = ((Join-Path $himmelRoot 'scripts\hooks\auto-approve-safe-bash.sh') -replace '\\', '/')
    $settingsTmp = Join-Path ([System.IO.Path]::GetTempPath()) "crys-settings-$PID.json"
    $settingsJson = @"
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash $hookPath" }
        ]
      }
    ]
  }
}
"@
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsTmp, $settingsJson, $enc)

    $noteDir = Split-Path -Parent (Resolve-Path -LiteralPath $NotePath).Path
    $claudeArgs = @()
    if ($env:CRYSTALLIZE_MODEL) { $claudeArgs += @('--model', $env:CRYSTALLIZE_MODEL) }
    if ($TranscriptPath) {
        $trParent = Split-Path -Parent $TranscriptPath
        if ($trParent -and (Test-Path -LiteralPath $trParent)) { $claudeArgs += @('--add-dir', $trParent) }
    }
    $claudeArgs += @('--settings', $settingsTmp, '--permission-mode', 'acceptEdits', $prompt)
    $env:CRYSTALLIZE_NOTE = $NotePath
    $env:CRYSTALLIZE_TRANSCRIPT = $TranscriptPath

    $hashBefore = (Get-FileHash -LiteralPath $NotePath -Algorithm SHA256).Hash

    try {
        . (Join-Path $himmelRoot 'scripts\lib\native-auth-pin.ps1')
        NativeAuthPinEnv
    } catch { exit 0 }

    Push-Location $noteDir
    [Environment]::CurrentDirectory = $noteDir
    try {
        $null | & $bin @claudeArgs *> $null
    } finally {
        Pop-Location
    }

    $hashAfter = (Get-FileHash -LiteralPath $NotePath -Algorithm SHA256).Hash
    if ($hashBefore -and $hashAfter -and ($hashBefore -ne $hashAfter)) {
        $valid = $true
        if ($refresh) {
            $rl = @(Get-Content -LiteralPath $NotePath)
            if (-not $rl -or $rl[0] -ne '---') { $valid = $false }
            elseif (@($rl | Where-Object { $_ -eq '---' }).Count -lt 2) { $valid = $false }
            elseif (($rl -notcontains '## Summary') -or ($rl -notcontains '## Decisions') -or
                    ($rl -notcontains '## Files Touched') -or ($rl -notcontains '## Follow-ups')) { $valid = $false }
            elseif ($rl -notcontains '> [!note]- Raw conversation') { $valid = $false }
        }
        if (-not $valid) {
            if ($snapTmp -and (Test-Path -LiteralPath $snapTmp)) {
                Move-Item -LiteralPath $snapTmp -Destination $NotePath -Force
                $snapTmp = $null
            }
        } else {
            $now = if ($env:CRYSTALLIZE_NOW) { $env:CRYSTALLIZE_NOW } else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            $fmc = 0
            $stamped = New-Object System.Collections.Generic.List[string]
            foreach ($line in (Get-Content -LiteralPath $NotePath)) {
                if ($line -eq '---') { $fmc++; $stamped.Add($line); continue }
                if ($fmc -eq 1 -and $line -match '^crystallized: ') { $stamped.Add('crystallized: true'); continue }
                if ($fmc -eq 1 -and $line -match '^crystallized_at:') { $stamped.Add("crystallized_at: $now"); continue }
                $stamped.Add($line)
            }
            [System.IO.File]::WriteAllText($NotePath, (($stamped -join "`n") + "`n"), $enc)
        }
    }
} finally {
    Remove-Item -LiteralPath $myPid -Force -ErrorAction SilentlyContinue
    if ($settingsTmp) { Remove-Item -LiteralPath $settingsTmp -Force -ErrorAction SilentlyContinue }
    if ($snapTmp) { Remove-Item -LiteralPath $snapTmp -Force -ErrorAction SilentlyContinue }
}
exit 0
