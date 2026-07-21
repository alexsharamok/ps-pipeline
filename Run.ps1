# Wrapper that substitutes $(NAME) tokens in a script with values from .env,
# fails before running if any required token is missing, then executes the
# rendered script. The rendered copy is written to a temp file so you can
# inspect what actually ran on failure.
#
# Pipeline mode: if -ScriptPath is omitted, copies all files from `src/`
# (recursively, preserving subdirectories) into the `.p/stages/` subdirectory
# (on a fresh run). Stage scripts live under `.p/stages/<NN-folder>/<NN-stage>.ps1`;
# the pipeline iterates folders (sorted by leading number) and then stages
# within each folder. Files at the src/ root that are not stages are also
# mirrored into the project root as helpers (so stages can call `.\helper.ps1`).
# The current working directory stays at the project root while each stage runs.
# On -Resume `.p/stages/` is also rebuilt from `src/`, but the git branch and
# start-pipeline commit from the prior run are left intact.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ScriptPath,

    [string]$EnvPath = (Join-Path $PSScriptRoot '.env'),

    [string]$StartAt,

    [string]$StopAfter,

    [string]$StartFolder,

    [string]$StopFolder,

    [string]$OnlyFolder,

    [int[]]$SkipSteps,

    [int[]]$RunOnly,

    [switch]$Resume,

    [switch]$Clean,

    [switch]$Clear,

    [switch]$DoNotCopySrc,

    [switch]$NoCommit,

    [switch]$SkipClearingLogs
)

function Write-Err($msg) {
    Write-Host $msg -ForegroundColor Red
}

$envRefRx = [regex]'\$\(([A-Za-z_][A-Za-z0-9_.]*)\)'

function Resolve-EnvKey {
    param(
        [string]$Key,
        [hashtable]$Raw,
        [hashtable]$Resolved,
        [hashtable]$UserEnv,
        [System.Collections.Generic.List[string]]$Stack
    )
    if ($Resolved.ContainsKey($Key)) { return $Resolved[$Key] }
    if ($UserEnv.ContainsKey($Key)) {
        $Resolved[$Key] = $UserEnv[$Key]
        return $UserEnv[$Key]
    }
    if (-not $Raw.ContainsKey($Key)) { return '' }
    if ($Stack.Contains($Key)) {
        $chain = (@($Stack) + $Key) -join ' -> '
        throw "Circular reference in .env: $chain"
    }
    [void]$Stack.Add($Key)
    $value = $envRefRx.Replace($Raw[$Key], {
        param($m)
        Resolve-EnvKey $m.Groups[1].Value $Raw $Resolved $UserEnv $Stack
    })
    [void]$Stack.Remove($Key)
    $Resolved[$Key] = $value
    return $value
}

function Read-EnvFile {
    param([string]$Path, [hashtable]$UserEnv)
    $raw = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $raw[$trimmed.Substring(0, $idx).Trim()] = $trimmed.Substring($idx + 1)
    }
    $resolved = @{}
    foreach ($key in @($raw.Keys)) {
        [void](Resolve-EnvKey -Key $key -Raw $raw -Resolved $resolved -UserEnv $UserEnv -Stack ([System.Collections.Generic.List[string]]::new()))
    }
    return $resolved
}

function Invoke-WithRollingTail {
    param([scriptblock]$Block, [string]$LogPath, [ref]$StderrFlag)

    $tailSize = 8
    $tail = [System.Collections.Generic.Queue[string]]::new()
    $esc = [char]27
    # The uniform CLI (colorette/picocolors) force-enables ANSI color on win32 even
    # when piped, so log lines arrive with escape codes; strip them for the file only.
    $ansiRx = [regex]::new("$esc\[[0-9;]*[A-Za-z]", [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $useAnsi = -not [Console]::IsOutputRedirected
    $width = if ($useAnsi) { [Math]::Max(20, [Console]::WindowWidth - 1) } else { 0 }
    $lastDraw = [DateTime]::MinValue
    $hadStderr = $false
    $writer = $null
    if ($LogPath) {
        $writer = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.UTF8Encoding]::new($false))
    }
    if ($useAnsi) { 1..$tailSize | ForEach-Object { [Console]::WriteLine() } }

    $flush = {
        param([bool]$Final)
        [Console]::Write("${esc}[${tailSize}F${esc}[0J")
        foreach ($l in $tail.ToArray()) {
            $d = if ($l.Length -gt $width) { $l.Substring(0, $width) } else { $l }
            [Console]::WriteLine($d)
        }
        if (-not $Final) {
            for ($i = $tail.Count; $i -lt $tailSize; $i++) { [Console]::WriteLine() }
        }
    }.GetNewClosure()

    try {
        & $Block 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord] -and
                "$_" -notmatch 'The .?punycode.? module is deprecated\. Please use a userland alternative instead') {
                $hadStderr = $true
            }
            $line = "$_"
            if ($writer) { $writer.WriteLine($ansiRx.Replace($line, '')) }
            if ($useAnsi) {
                $tail.Enqueue($line)
                while ($tail.Count -gt $tailSize) { [void]$tail.Dequeue() }
                $now = [DateTime]::UtcNow
                if (($now - $lastDraw).TotalMilliseconds -ge 50) {
                    & $flush
                    $lastDraw = $now
                }
            } else {
                [Console]::WriteLine($line)
            }
        }
        if ($useAnsi) {
            & $flush $true
            # One separator line after a block that produced output keeps
            # consecutive commands readable without runs of padding blanks.
            if ($tail.Count -gt 0) { [Console]::WriteLine() }
        }
    } finally {
        if ($writer) { $writer.Dispose() }
    }
    if ($StderrFlag) { $StderrFlag.Value = $hadStderr }
}

function Invoke-RenderedScript {
    param([string]$ScriptPath, [hashtable]$EnvVars, [string]$LogPath, [ref]$StderrFlag)

    $content = Get-Content -LiteralPath $ScriptPath -Raw
    $rx = [regex]'\$\(([A-Za-z_][A-Za-z0-9_.]*)\)'
    $tokens = $rx.Matches($content) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    $missing = @($tokens | Where-Object {
        -not $EnvVars.ContainsKey($_) -and
        [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, 'Process'))
    })
    $enforce = $content -match 'Enforce all env vars'
    if ($missing.Count -gt 0) {
        if ($enforce) {
            Write-Err "ERROR: Missing required variables for ${ScriptPath}:"
            $missing | ForEach-Object { Write-Err "  - $_" }
            return 1
        }
        Write-Host "WARNING: Missing variables for ${ScriptPath} (replacing with empty):" -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host ""
    }

    $rendered = $rx.Replace($content, {
        param($m)
        $key = $m.Groups[1].Value
        if ($EnvVars.ContainsKey($key)) { return $EnvVars[$key] }
        $procVal = [Environment]::GetEnvironmentVariable($key, 'Process')
        if ($procVal) { return $procVal }
        return ''
    })

    # Rewrite CWD-relative helper references (`.\_helper.ps1`, incl. quoted
    # `'.\helper.ps1'`) to the helper's absolute path under .p/stages. Stages
    # run with cwd = repo root; without this the helpers would have to be
    # mirrored into the root for `.\` to resolve. The `.\` prefix is the anchor,
    # and only known root-helper basenames are rewritten, so stage-local paths
    # are untouched. (helpers reference each other via $PSScriptRoot, which is
    # correct once they load from .p/stages.)
    if ($script:RootHelperMap -and $script:RootHelperMap.Count -gt 0) {
        foreach ($h in $script:RootHelperMap.GetEnumerator()) {
            $pat = '\.\\' + [regex]::Escape($h.Key)
            $abs = $h.Value
            $rendered = [regex]::Replace(
                $rendered, $pat, { param($m) $abs }.GetNewClosure(),
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "rendered_$name.ps1"
    Set-Content -LiteralPath $tempFile -Value $rendered -Encoding utf8

    $previousEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $previousCwd = Get-Location
    $hadStderr = $false
    try {
        $global:LASTEXITCODE = 0
        if ($LogPath) {
            $tf = $tempFile
            Invoke-WithRollingTail -Block { & $tf }.GetNewClosure() -LogPath $LogPath -StderrFlag ([ref]$hadStderr)
        } else {
            & $tempFile | Out-Host
        }
        if ($StderrFlag) { $StderrFlag.Value = $hadStderr }
        return $LASTEXITCODE
    } catch {
        Write-Host ($_ | Out-String) -ForegroundColor Red
        return 1
    } finally {
        $ErrorActionPreference = $previousEAP
        Set-Location $previousCwd
    }
}


function Invoke-Git {
    $gitArgs = $args
    Invoke-WithRollingTail -Block { & git @gitArgs }.GetNewClosure()
}

function Get-RunBranch {
    $Project = $([System.IO.Path]::GetFileName($PSScriptRoot))
    return "runs/$Project-$AttemptNumber"
}

function Git-Setup {
    if ($NoCommit) { Write-Host "Skipping working tree reset (-NoCommit)"; return }
    Write-Host "Resetting working tree"

    $BranchName = Get-RunBranch

    Invoke-Git checkout -B $BranchName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-Git reset --hard
    Invoke-Git clean -f
}

function Git-Clean(
    [string] $StageName
) {
    if ($NoCommit) { Write-Host "Skipping working tree clean (-NoCommit)"; return }
    Write-Host "Cleaning working tree to previous stage of $StageName"

    if ($StageName -notmatch '^(\d+)[^/]*/(\d+)') {
        Write-Err "ERROR: -Clean target stage must look like '<NN-folder>/<NN-stage>', got: $StageName"
        exit 1
    }
    $startFolderNum = [int]$matches[1]
    $startStageNum  = [int]$matches[2]

    $BranchName = Get-RunBranch

    $Project = $([System.IO.Path]::GetFileName($PSScriptRoot))
    $msgPattern = " \($Project/$AttemptNumber\)"
    $commits = git log --format='%H%x09%s' $BranchName 2>$null
    $targetSha = $null
    foreach ($entry in $commits) {
        $parts = $entry -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $sha = $parts[0]; $subject = $parts[1]
        if ($subject -notmatch $msgPattern) { continue }
        if ($subject -match '^(\d+)[^/]*/(\d+)') {
            $folderNum = [int]$matches[1]
            $stageNum  = [int]$matches[2]
            if ($folderNum -lt $startFolderNum -or
                ($folderNum -eq $startFolderNum -and $stageNum -lt $startStageNum)) {
                $targetSha = $sha
                break
            }
        }
    }

    if (-not $targetSha) {
        Write-Err "ERROR: -Clean found no prior stage commit on $BranchName before $startFolderNum/$startStageNum"
        exit 1
    }

    Write-Host "Resetting $BranchName to $targetSha"
    Invoke-Git checkout $BranchName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-Git reset --hard $targetSha
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Invoke-Git clean -f
}

function Git-Commit-Running(
    [string] $StageName
) {
    if ($NoCommit) { return }
    Write-Host "Pre-stage commit (RUNNING)`n"

    $Project = $([System.IO.Path]::GetFileName($PSScriptRoot))

    Invoke-Git add z_stdout
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $msg = "$StageName ($Project/$AttemptNumber) - stage started"
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git commit --allow-empty -m $msg
    } else {
        Invoke-Git commit -m $msg
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Git-Commit(
    [string] $StageName,
    [string] $LogPath
) {
    if ($NoCommit) { return }
    Write-Host "Amending RUNNING commit with stage results`n"

    $Project = $([System.IO.Path]::GetFileName($PSScriptRoot))

    Invoke-Git add *
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $nameStatus = & git diff --cached --name-status
    $changed = 0
    $new = 0
    foreach ($entry in $nameStatus) {
        if (-not $entry) { continue }
        $parts = $entry -split "`t"
        if ($parts.Count -lt 2) { continue }
        $status = $parts[0]
        $path = $parts[-1]
        if ($path -match '^z_stdout(/|\\)') { continue }
        switch -Regex ($status) {
            '^A'      { $new++ }
            '^[MRTD]' { $changed++ }
        }
    }

    $suffixParts = @()
    if ($changed -gt 0) { $suffixParts += "$changed changed" }
    if ($new -gt 0)     { $suffixParts += "$new new" }

    # Deploy/publish stages leave no working-tree changes behind; their real
    # outcome is what the uniform CLI pushed/published. Count its per-item
    # marker lines from the stage log ([A] added, [U] updated, [D] deleted,
    # [P] published) so the commit message reflects the remote effect.
    if ($LogPath -and $StageName -match '^\d+-(deploy|publish)/' -and (Test-Path -LiteralPath $LogPath)) {
        $markerCounts = @{}
        foreach ($line in [System.IO.File]::ReadLines($LogPath)) {
            if ($line -match '^\[([A-Z])\]\s') {
                $markerCounts[$matches[1]] = [int]$markerCounts[$matches[1]] + 1
            }
        }
        $markerWords = @{ 'A' = 'added'; 'U' = 'updated'; 'D' = 'deleted'; 'P' = 'published' }
        foreach ($key in @('A'; 'U'; 'D'; 'P') + @($markerCounts.Keys | Where-Object { $_ -notin 'A', 'U', 'D', 'P' } | Sort-Object)) {
            if ($markerCounts[$key]) {
                $word = if ($markerWords[$key]) { $markerWords[$key] } else { "[$key]" }
                $suffixParts += "$($markerCounts[$key]) $word"
            }
        }
    }

    $suffix = if ($suffixParts.Count -gt 0) { $suffixParts -join ', ' } else { 'no changes' }

    $CommitMessage = "$StageName ($Project/$AttemptNumber) - $suffix"

    Invoke-Git commit --amend --allow-empty -m $CommitMessage
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Git-Commit-Failed(
    [string] $StageName
) {
    if ($NoCommit) { return }
    Write-Host "Amending RUNNING commit (stage failed or aborted)`n"

    $Project = $([System.IO.Path]::GetFileName($PSScriptRoot))

    Invoke-Git add *

    $CommitMessage = "$StageName ($Project/$AttemptNumber) - failed or aborted"
    Invoke-Git commit --amend --allow-empty -m $CommitMessage
}

$savedEnv = @{}
foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
    $savedEnv[$entry.Key] = $entry.Value
}

try {

if (-not (Test-Path -LiteralPath $EnvPath)) {
    Write-Err "ERROR: .env not found: $EnvPath"
    exit 1
}
try {
    $envVars = Read-EnvFile -Path $EnvPath -UserEnv $savedEnv
} catch {
    $ex = $_.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    Write-Err "ERROR loading ${EnvPath}: $($ex.Message)"
    exit 1
}

foreach ($key in @($envVars.Keys)) {
    if ($key -notmatch '[=\x00]' -and -not $savedEnv.ContainsKey($key)) {
        [Environment]::SetEnvironmentVariable($key, $envVars[$key], 'Process')
    }
}

if ($ScriptPath) {
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Err "ERROR: Script not found: $ScriptPath"
        exit 1
    }
    exit (Invoke-RenderedScript -ScriptPath $ScriptPath -EnvVars $envVars)
}

# Pipeline mode
Write-Host "PIPELINE MODE"

$stdoutDir = Join-Path (Get-Location) 'z_stdout'
if (-not (Test-Path -LiteralPath $stdoutDir)) {
    New-Item -ItemType Directory -Path $stdoutDir -Force | Out-Null
}

if (-not $SkipClearingLogs -and ($Clear -or -not $Resume)) {
    Get-ChildItem -Path $stdoutDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Deleting z_stdout/$($_.Name)"
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$statusFilePath = Join-Path (Get-Location) '.p/current-state.json'
$statusFileDir = Split-Path -Path $statusFilePath -Parent
if ($statusFileDir -and -not (Test-Path -LiteralPath $statusFileDir)) {
    New-Item -ItemType Directory -Path $statusFileDir -Force | Out-Null
}

$status = @{}
if (Test-Path -LiteralPath $statusFilePath) {
    try {
        $existing = Get-Content -LiteralPath $statusFilePath -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) {
            $status[$prop.Name] = $prop.Value
        }
    } catch {
        Write-Err "ERROR: failed to parse .p/current-state.json: $($_.Exception.Message)"
        exit 1
    }
}

# Prefer deriving state from git; .p/current-state.json (loaded above) is only a
# fallback for whatever git can't provide.
#   lastAttemptNumber       <- current branch name, e.g. 178 from "runs/cha-178"
#     (the "cha" prefix is not fixed; any "runs/<prefix>-<N>" works)
#   currentPipelineStageIndex / currentFolderIndex <- HEAD commit subject, e.g.
#     "4318" (+ folder "3") from
#       "3-transform/4318-remove-unused-frontend-parameters.ps1 (cha/178) - stage started"
#     or "18" (no folder) from
#       "18-remove-unused-frontend-parameters.ps1 (cha/178) - failed"
$gitBranch = (& git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
if ($gitBranch -match '^runs/.+-(\d+)$') {
    $status['lastAttemptNumber'] = [int]$matches[1]
}
$gitSubject = (& git log -1 --format='%s' 2>$null | Out-String).Trim()
if ($gitSubject) {
    # The stage identifier is the first whitespace-delimited token: an optional
    # "<folderNN>-<folderName>/" prefix followed by "<stageNN>-<stageName>.ps1".
    $stageToken = ($gitSubject -split '\s+')[0]
    if ($stageToken -match '^(?:(\d+)-[^/]+/)?(\d+)-') {
        if ($matches[1]) { $status['currentFolderIndex'] = $matches[1] }
        $status['currentPipelineStageIndex'] = $matches[2]
    }
}

$lastAttempt = 0
if ($status.ContainsKey('lastAttemptNumber')) {
    $lastAttempt = [int]$status['lastAttemptNumber']
}

if ($Clean -and -not $Resume) {
    Write-Err "ERROR: -Clean requires -Resume"
    exit 1
}

if ($Resume) {
    # The saved resume point (currentFolderIndex + currentPipelineStageIndex) is
    # only auto-applied when the user did NOT explicitly narrow the start with
    # -StartAt or -StartFolder. Passing either flag is an override, so the stale
    # saved folder must not be layered on top of it (e.g. -StartAt 4511 must not
    # be forced forward by a saved folder of 5).
    if (-not $StartAt -and -not $StartFolder) {
        if (-not $status.ContainsKey('currentPipelineStageIndex')) {
            Write-Err "ERROR: -Resume requires currentPipelineStageIndex in .p/current-state.json"
            exit 1
        }
        $StartAt = [string]$status['currentPipelineStageIndex']
        if (-not $StartAt) {
            Write-Err "ERROR: .p/current-state.json has no currentPipelineStageIndex"
            exit 1
        }
        if ($status.ContainsKey('currentFolderIndex')) {
            $StartFolder = [string]$status['currentFolderIndex']
        }
    }
    if ($lastAttempt -lt 1) {
        Write-Err "ERROR: -Resume but no previous lastAttemptNumber in .p/current-state.json"
        exit 1
    }
    $AttemptNumber = $lastAttempt
} else {
    $AttemptNumber = $lastAttempt + 1
    $status['lastAttemptNumber'] = $AttemptNumber
    $status | ConvertTo-Json | Set-Content -LiteralPath $statusFilePath -Encoding utf8
}

$pipelineDir = Join-Path $PSScriptRoot '.p/stages'

if (-not $Resume) {
    Git-Setup
}

if ($DoNotCopySrc -and -not $Resume) {
    Write-Err "ERROR: -DoNotCopySrc requires -Resume (fresh runs must build .p/stages from src)"
    exit 1
}

if (-not $DoNotCopySrc) {
if (Test-Path -LiteralPath $pipelineDir) {
    Remove-Item -LiteralPath $pipelineDir -Recurse -Force
}
New-Item -ItemType Directory -Path $pipelineDir -Force | Out-Null
$cacheLine = "### IMPORTANT ### PIPELINE CACHE ###  DO NOT MODIFY THIS FILE ###"
$cacheBlock = (1..10 | ForEach-Object { $cacheLine }) -join "`r`n"
$srcDir = Join-Path $PSScriptRoot 'src'
if (-not (Test-Path -LiteralPath $srcDir)) {
    Write-Err "ERROR: src folder not found: $srcDir"
    exit 1
}
$srcRootFull = (Resolve-Path -LiteralPath $srcDir).Path
$plannedDests = @{}
Get-ChildItem -LiteralPath $srcDir -File -Recurse |
    Where-Object {
        # src/data/ holds git-tracked config + seed content (categories/icons/
        # redirects/slots-order + seed-content). Stages read it by absolute path
        # via $(SrcDataDir)/$(ContentSeedDir), so it must NOT be copied into
        # .p/stages: the flatten-to-<topfolder>/<basename> rule would mangle its
        # nested tree and bloat every stage commit.
        $_.Name -ne '.gitignore' -and
        ($_.FullName.Substring($srcRootFull.Length).TrimStart('\', '/') -notmatch '^data[\\/]')
    } |
    ForEach-Object {
        $relative = $_.FullName.Substring($srcRootFull.Length).TrimStart('\', '/')
        $segments = $relative -split '[\\/]'

        # Flatten: inside any src/<folder>/..., keep only top-level folder and
        # the file's basename. Files at the src/ root pass through.
        if ($segments.Count -le 1) {
            $destRel = $relative
        } else {
            $destRel = Join-Path $segments[0] $_.Name
        }

        if ($plannedDests.ContainsKey($destRel)) {
            Write-Err "ERROR: Multiple src files flatten to the same destination ${destRel}:"
            Write-Err "  $($plannedDests[$destRel])"
            Write-Err "  $($_.FullName)"
            exit 1
        }
        $plannedDests[$destRel] = $_.FullName

        $dest = Join-Path $pipelineDir $destRel
        $destParent = Split-Path -Path $dest -Parent
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        if ($_.Extension -eq '.ps1') {
            $body = Get-Content -LiteralPath $_.FullName -Raw
            if ($null -eq $body) { $body = '' }
            $content = "$cacheBlock`r`n`r`n$body`r`n`r`n$cacheBlock"
            Set-Content -LiteralPath $dest -Value $content -Encoding utf8 -NoNewline
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }

        # Helpers (non-stage files at the src/ root) are NOT mirrored into the
        # project root. Stages call them CWD-relative (`. .\helper.ps1`); the
        # render step (Invoke-RenderedScript) rewrites those references to the
        # helper's absolute path under .p/stages, so the repo root stays clean.
    }
}

if (-not $Resume -and -not $NoCommit) {
    Invoke-Git add .p/stages
    Invoke-Git add -A z_stdout
    & git -C $PSScriptRoot diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        Invoke-Git commit -m 'start pipeline (cha/99)'
    }
}

if (-not (Test-Path -LiteralPath $pipelineDir)) {
    Write-Err "ERROR: stages folder not found: $pipelineDir"
    exit 1
}

# Map of root-helper basename -> absolute path under .p/stages. Top-level
# *.ps1 in .p/stages that don't start with a stage number are exactly the
# flattened src/-root helpers (RunSiphon, _uniform-retry, insert-*, ...).
# Stages reference them CWD-relative (`. .\_helper.ps1`); Invoke-RenderedScript
# rewrites each `.\<helper>` to its absolute path here, so the helpers no
# longer need mirroring into the repo root. Built from .p/stages so it works
# for both fresh and -Resume/-DoNotCopySrc runs (which don't rebuild it).
$pipelineFull = (Resolve-Path -LiteralPath $pipelineDir).Path
$script:RootHelperMap = @{}
Get-ChildItem -LiteralPath $pipelineFull -File -Filter '*.ps1' |
    Where-Object { $_.Name -notmatch '^\d+-' } |
    ForEach-Object { $script:RootHelperMap[$_.Name] = $_.FullName }

$folderDirs = @(Get-ChildItem -Path $pipelineDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+' } |
    Sort-Object Name)
if ($folderDirs.Count -eq 0) {
    Write-Err "ERROR: No stage folders matching ^\d+ found in $pipelineDir"
    exit 1
}

$dupFolders = $folderDirs |
    Group-Object { if ($_.Name -match '^(\d+)') { $matches[1] } else { '' } } |
    Where-Object { $_.Count -gt 1 }
if ($dupFolders) {
    Write-Err "ERROR: Duplicate leading numbers in stage folders:"
    foreach ($g in $dupFolders) {
        Write-Err "  $($g.Name): $((($g.Group | ForEach-Object { $_.Name }) -join ', '))"
    }
    exit 1
}

$pipelineItems = @()
foreach ($folder in $folderDirs) {
    $stageFiles = @(Get-ChildItem -Path $folder.FullName -Filter '*.ps1' -File |
        Where-Object { $_.Name -match '^\d+' } |
        Sort-Object Name)
    foreach ($s in $stageFiles) {
        $pipelineItems += [pscustomobject]@{
            Folder   = $folder.Name
            Stage    = $s.Name
            Display  = "$($folder.Name)/$($s.Name)"
            FullPath = $s.FullName
            LogName  = "$($folder.Name)--$([System.IO.Path]::GetFileNameWithoutExtension($s.Name)).log"
        }
    }
}

if ($pipelineItems.Count -eq 0) {
    Write-Err "ERROR: No stages found under $pipelineDir/<folder>/NN*.ps1"
    exit 1
}

$dupStages = $pipelineItems |
    Group-Object { if ($_.Stage -match '^(\d+)') { $matches[1] } else { '' } } |
    Where-Object { $_.Count -gt 1 }
if ($dupStages) {
    Write-Err "ERROR: Duplicate leading numbers in stages (must be unique across all folders):"
    foreach ($g in $dupStages) {
        Write-Err "  $($g.Name): $((($g.Group | ForEach-Object { $_.Display }) -join ', '))"
    }
    exit 1
}

function Filter-ByFolder {
    param([string]$Filter, [string]$Mode, $Items)
    if (-not $Filter) { return $Items }
    if ($Filter -match '^(\d+)') {
        $n = [int]$matches[1]
        if ($Mode -eq 'only') {
            return @($Items | Where-Object {
                ($_.Folder -match '^(\d+)') -and ([int]$matches[1] -eq $n)
            })
        } elseif ($Mode -eq 'start') {
            return @($Items | Where-Object {
                ($_.Folder -match '^(\d+)') -and ([int]$matches[1] -ge $n)
            })
        } else {
            return @($Items | Where-Object {
                ($_.Folder -match '^(\d+)') -and ([int]$matches[1] -le $n)
            })
        }
    }
    if ($Mode -eq 'only') {
        return @($Items | Where-Object { $_.Folder -like "*$Filter*" })
    } elseif ($Mode -eq 'start') {
        $idx = -1
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($Items[$i].Folder -like "*$Filter*") { $idx = $i; break }
        }
        if ($idx -lt 0) { return @() }
        return @($Items[$idx..($Items.Count - 1)])
    } else {
        $idx = -1
        for ($i = $Items.Count - 1; $i -ge 0; $i--) {
            if ($Items[$i].Folder -like "*$Filter*") { $idx = $i; break }
        }
        if ($idx -lt 0) { return @() }
        return @($Items[0..$idx])
    }
}

if ($OnlyFolder) {
    $pipelineItems = Filter-ByFolder -Filter $OnlyFolder -Mode 'only' -Items $pipelineItems
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -OnlyFolder $OnlyFolder matches no folders"
        exit 1
    }
}

if ($StartFolder) {
    $pipelineItems = Filter-ByFolder -Filter $StartFolder -Mode 'start' -Items $pipelineItems
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -StartFolder $StartFolder matches no folders"
        exit 1
    }
}

if ($StopFolder) {
    $pipelineItems = Filter-ByFolder -Filter $StopFolder -Mode 'stop' -Items $pipelineItems
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -StopFolder $StopFolder matches no folders"
        exit 1
    }
}

if ($StartAt) {
    if ($StartAt -match '^(\d+)') {
        $resumeNum = [int]$matches[1]
        $pipelineItems = @($pipelineItems | Where-Object {
            ($_.Stage -match '^(\d+)') -and ([int]$matches[1] -ge $resumeNum)
        })
    } else {
        $startIndex = -1
        for ($i = 0; $i -lt $pipelineItems.Count; $i++) {
            if ($pipelineItems[$i].Stage -like "*$StartAt*") { $startIndex = $i; break }
        }
        if ($startIndex -ge 0) {
            $pipelineItems = @($pipelineItems[$startIndex..($pipelineItems.Count - 1)])
        } else {
            $pipelineItems = @()
        }
    }
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -StartAt $StartAt matches no stages"
        exit 1
    }
    Write-Host "Resuming from $($pipelineItems[0].Display) (skipped earlier steps)"
}

if ($StopAfter) {
    if ($StopAfter -match '^(\d+)') {
        $stopNum = [int]$matches[1]
        $pipelineItems = @($pipelineItems | Where-Object {
            ($_.Stage -match '^(\d+)') -and ([int]$matches[1] -le $stopNum)
        })
    } else {
        $endIndex = -1
        for ($i = 0; $i -lt $pipelineItems.Count; $i++) {
            if ($pipelineItems[$i].Stage -like "*$StopAfter*") { $endIndex = $i; break }
        }
        if ($endIndex -ge 0) {
            $pipelineItems = @($pipelineItems[0..$endIndex])
        } else {
            $pipelineItems = @()
        }
    }
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -StopAfter $StopAfter matches no stages"
        exit 1
    }
    Write-Host "Stopping after $($pipelineItems[-1].Display) (later steps skipped)"
}

if ($SkipSteps) {
    $skipSet = @{}
    foreach ($n in $SkipSteps) { $skipSet[[int]$n] = $true }
    $pipelineItems = @($pipelineItems | Where-Object {
        -not (($_.Stage -match '^(\d+)') -and $skipSet.ContainsKey([int]$matches[1]))
    })
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -SkipSteps $($SkipSteps -join ',') skipped all stages"
        exit 1
    }
    Write-Host "Skipping steps: $($SkipSteps -join ', ')"
}

if ($RunOnly) {
    $runSet = @{}
    foreach ($n in $RunOnly) { $runSet[[int]$n] = $true }
    $pipelineItems = @($pipelineItems | Where-Object {
        ($_.Stage -match '^(\d+)') -and $runSet.ContainsKey([int]$matches[1])
    })
    if ($pipelineItems.Count -eq 0) {
        Write-Err "ERROR: -RunOnly $($RunOnly -join ',') matches no stages"
        exit 1
    }
    Write-Host "Running only steps: $($RunOnly -join ', ')"
}

if ($Clean) {
    Git-Clean -StageName $pipelineItems[0].Display
}

$runningStage = $null
foreach ($item in $pipelineItems) {
    $folderPrefix = if ($item.Folder -match '^(\d+)') { $matches[1] } else { '' }
    $stagePrefix  = if ($item.Stage  -match '^(\d+)') { $matches[1] } else { '' }
    $status['currentFolderIndex'] = $folderPrefix
    $status['currentPipelineStageIndex'] = $stagePrefix
    $status['stderr'] = $false
    $status | ConvertTo-Json | Set-Content -LiteralPath $statusFilePath -Encoding utf8

    Write-Host ('=' * 79)
    Write-Host ("RUNNING $($item.Display) ".PadRight(79, '='))
    Write-Host ""
    $logPath = Join-Path $stdoutDir $item.LogName
    if (-not (Test-Path -LiteralPath $stdoutDir)) {
        New-Item -ItemType Directory -Path $stdoutDir -Force | Out-Null
    }
    Set-Content -LiteralPath $logPath -Value '' -Encoding utf8 -NoNewline
    Git-Commit-Running -StageName $item.Display

    # From here until the success commit below, an exit (stage non-zero, a
    # 'Must change/create files' violation) or a Ctrl+C abort leaves this set,
    # so the finally block amends the RUNNING commit as "failed or aborted".
    $runningStage = $item.Display

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stderrFlag = $false
    $code = Invoke-RenderedScript -ScriptPath $item.FullPath -EnvVars $envVars -LogPath $logPath -StderrFlag ([ref]$stderrFlag)
    $status['stderr'] = [bool]$stderrFlag
    $status | ConvertTo-Json | Set-Content -LiteralPath $statusFilePath -Encoding utf8
    $sw.Stop()
    $elapsed = $sw.Elapsed.ToString('hh\:mm\:ss\.fff')
    Write-Host "DONE $($item.Display), Elapsed: $elapsed"
    Write-Host ""

    if ($code -ne 0) {
        Write-Err "Pipeline halted: $($item.Display) exited with code $code"
        exit $code
    }

    $stageContent = Get-Content -LiteralPath $item.FullPath -Raw
    $mustChange = $stageContent -match 'Must change files'
    $mustCreate = $stageContent -match 'Must create files'
    if ($mustChange -or $mustCreate) {
        $porcelain = git status --porcelain |
            Where-Object { ($_.Substring(3) -notmatch '^z_stdout(/|\\)') }
        $modified = @($porcelain | Where-Object { $_ -match '^( M|M |MM|AM| T| R| C| D|D )' })
        $created = @($porcelain | Where-Object { $_ -match '^(\?\?|A |AM)' })
        if ($mustChange -and $modified.Count -eq 0) {
            Write-Err "Pipeline halted: $($item.Display) declares 'Must change files' but no existing files were modified"
            exit 1
        }
        if ($mustCreate -and $created.Count -eq 0) {
            Write-Err "Pipeline halted: $($item.Display) declares 'Must create files' but no new files were created"
            exit 1
        }
    }

    Git-Commit -StageName $item.Display -LogPath $logPath
    # Stage results are committed; a later merge failure must not overwrite
    # this good commit with a "failed or aborted" message.
    $runningStage = $null

    $mergeMatch = [regex]::Match($stageContent, 'On success merge with\s+(\S+)')
    if ($mergeMatch.Success -and -not $NoCommit) {
        $targetBranch = $mergeMatch.Groups[1].Value.Trim('"', "'")
        $runBranch = Get-RunBranch
        Write-Host "Merging $runBranch into $targetBranch (run branch wins all conflicts, no checkout)"
        $headSha = (& git rev-parse HEAD | Out-String).Trim()
        $tree = (& git log -1 --format=%T HEAD | Out-String).Trim()
        if (-not $tree) {
            Write-Err "Pipeline halted: could not resolve HEAD tree"
            exit 1
        }
        $targetSha = (git rev-parse --verify --quiet "refs/heads/$targetBranch" 2>$null)
        if ($targetSha) { $targetSha = $targetSha.Trim() }
        if (-not $targetSha) {
            Invoke-Git update-ref "refs/heads/$targetBranch" $headSha
        } else {
            $mergeMsg = "Merge $runBranch into $targetBranch ($($item.Display))"
            $mergeSha = (& git commit-tree $tree -p $targetSha -p $headSha -m $mergeMsg).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $mergeSha) {
                Write-Err "Pipeline halted: commit-tree failed for $targetBranch"
                exit 1
            }
            Invoke-Git update-ref "refs/heads/$targetBranch" $mergeSha $targetSha
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Pipeline halted: failed to merge $($item.Display) into $targetBranch"
            exit $LASTEXITCODE
        }
    }
}

if (-not $NoCommit) {
    & git branch -D runs/_last 2>$null | Out-Null
    Invoke-Git checkout -b runs/_last
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

} finally {
    if ($runningStage -and -not $NoCommit) {
        try {
            Git-Commit-Failed -StageName $runningStage
        } catch {
            Write-Host "WARNING: failed to commit failed/aborted stage $runningStage`: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($AttemptNumber) {
        $project = [System.IO.Path]::GetFileName($PSScriptRoot)
        $stdoutDir = Join-Path (Get-Location) 'z_stdout'
        if (Test-Path -LiteralPath $stdoutDir) {
            $archiveDir = Join-Path (Get-Location) '.archive'
            $runStdoutDir = Join-Path $archiveDir "$project-$AttemptNumber"
            try {
                if (-not (Test-Path -LiteralPath $runStdoutDir)) {
                    New-Item -ItemType Directory -Path $runStdoutDir -Force | Out-Null
                }
                Get-ChildItem -Path $stdoutDir -File -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        Copy-Item -LiteralPath $_.FullName -Destination $runStdoutDir -Force
                    } catch {
                        Write-Host "WARNING: failed to copy $($_.Name) to $runStdoutDir`: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host "WARNING: failed to archive logs into $runStdoutDir`: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    $currentVars = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($currentVars.Keys)) {
        if (-not $savedEnv.ContainsKey($key)) {
            [Environment]::SetEnvironmentVariable($key, $null, 'Process')
        }
    }
    foreach ($key in @($savedEnv.Keys)) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process')
    }
}
