$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}
if ($env:GIT_CUSTOMS_TEST_BIN) {
    $installDir = $env:GIT_CUSTOMS_TEST_BIN
}
else {
    $installDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts'
}
$env:PATH = "$installDir;$env:PATH"

$script:pass = 0
$script:fail = 0
$failures = New-Object 'System.Collections.Generic.List[string]'

function Check {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:pass++
        Write-Output "PASS: $Name"
    }
    else {
        $script:fail++
        $failures.Add($Name)
        Write-Output "FAIL: $Name"
    }
}

function Check-Equal {
    param([string]$Expected, [string]$Actual, [string]$Name)
    Check ($Expected -ceq $Actual) $Name
    if ($Expected -cne $Actual) {
        Write-Output "  expected: $Expected"
        Write-Output "  actual:   $Actual"
    }
}

function Check-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Name)
    Check ($Haystack.Contains($Needle)) $Name
    if (-not $Haystack.Contains($Needle)) {
        Write-Output "  missing: $Needle"
        if ($Haystack.Length -gt 4000) {
            Write-Output ('  output tail: ' + $Haystack.Substring($Haystack.Length - 4000))
        }
        else {
            Write-Output ('  output: ' + $Haystack)
        }
    }
}

function Run-Git {
    param([string]$WorkingDirectory, [string[]]$Arguments)
    $output = & git -C $WorkingDirectory @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "git -C `"$WorkingDirectory`" $($Arguments -join ' ') failed ($code): $($output -join "`n")"
    }
    return $output
}

function Invoke-Autopush {
    param([string]$WorkingDirectory, [string]$Arguments = 'autopush', [string]$Answer = 'y')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.WriteLine($Answer)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

function Set-HookFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $normalized = $Content.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($Path, $normalized, (New-Object System.Text.UTF8Encoding $false))
}

function New-BareOrigin {
    param([string]$Path)
    & git init --bare -q $Path
    if ($LASTEXITCODE -ne 0) { throw 'bare init failed' }
    Set-HookFile (Join-Path $Path 'hooks\pre-receive') @'
#!/bin/sh
echo push >> autopush-push-count
exit 0
'@
}

function New-WorkRepo {
    param([string]$Path, [string]$Origin)
    & git init -q -b main $Path
    if ($LASTEXITCODE -ne 0) { throw 'work init failed' }
    Run-Git $Path @('config', 'user.email', 'test@example.com') | Out-Null
    Run-Git $Path @('config', 'user.name', 'Test') | Out-Null
    Run-Git $Path @('remote', 'add', 'origin', $Origin) | Out-Null
}

function New-InitialCommit {
    param([string]$Path)
    Run-Git $Path @('add', '-A') | Out-Null
    Run-Git $Path @('commit', '-q', '-m', 'Initial commit') | Out-Null
    Run-Git $Path @('push', '-q', '-u', 'origin', 'main') | Out-Null
}

function Get-PushCount {
    param([string]$Origin)
    $file = Join-Path $Origin 'autopush-push-count'
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    return @(Get-Content -LiteralPath $file).Count
}

function Reset-PushCount {
    param([string]$Origin)
    Remove-Item -LiteralPath (Join-Path $Origin 'autopush-push-count') -Force -ErrorAction SilentlyContinue
}

$base = Join-Path $env:TEMP ('git-autopush-tests-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $notRepo = Join-Path $base 'not-a-repo'
    New-Item -ItemType Directory -Force -Path $notRepo | Out-Null

    # --- Main success scenario ---
    $origin = Join-Path $base 'origin-main.git'
    $work = Join-Path $base 'work repo'
    New-BareOrigin $origin
    New-WorkRepo $work $origin

    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'delete me.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'staged delete.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'staged only.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'rename old.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'z-staged.txt') -Value 'initial'
    New-InitialCommit $work

    Check-Equal '1' ([string](Get-PushCount $origin)) 'test pre-receive push counter works'
    Reset-PushCount $origin

    $cleanHead = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $clean = Invoke-Autopush $work
    Check-Equal 0 $clean.ExitCode 'clean repo autopush exits 0'
    Check-Contains $clean.Stdout 'is up to date.' 'clean repo reports up to date'
    Check-Contains $clean.Stdout 'Nothing to commit or push.' 'clean repo says nothing to push'
    Check-Equal '' $clean.Stderr.Trim() 'clean repo writes no stderr'
    Check-Equal $cleanHead (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim() 'clean repo does not change HEAD'
    Check-Equal '0' ([string](Get-PushCount $origin)) 'clean repo does not push'

    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'should not commit'
    $cancelHead = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $cancelStatus = (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim()
    $cancelled = Invoke-Autopush $work -Answer 'n'
    Check-Equal 0 $cancelled.ExitCode 'autopush cancellation exits cleanly'
    Check-Contains $cancelled.Stdout 'Autopush cancelled' 'autopush reports cancellation'
    Check-Equal $cancelHead (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim() 'cancelled autopush does not commit'
    Check-Equal $cancelStatus (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim() 'cancelled autopush does not stage files'
    Check-Equal '0' ([string](Get-PushCount $origin)) 'cancelled autopush does not push'
    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'initial'

    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'invalid answer must cancel'
    $invalidHead = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $invalidStatus = (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim()
    $invalidAnswer = Invoke-Autopush $work -Answer 'later'
    Check-Contains $invalidAnswer.Stdout 'Autopush cancelled' 'non-affirmative response cancels autopush'
    Check-Equal $invalidHead (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim() 'invalid confirmation does not commit'
    Check-Equal $invalidStatus (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim() 'invalid confirmation does not stage'
    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'initial'

    # Outside repository
    $outside = Invoke-Autopush $notRepo
    Check-Equal 1 $outside.ExitCode 'outside a repository exits 1'
    Check-Contains $outside.Stderr 'not inside a Git working tree' 'outside a repository error is clear'

    # No origin
    $noOrigin = Join-Path $base 'no-origin'
    & git init -q -b main $noOrigin
    if ($LASTEXITCODE -ne 0) { throw 'no-origin init failed' }
    Run-Git $noOrigin @('config', 'user.email', 'test@example.com') | Out-Null
    Run-Git $noOrigin @('config', 'user.name', 'Test') | Out-Null
    Set-Content -LiteralPath (Join-Path $noOrigin 'a.txt') -Value 'a'
    Run-Git $noOrigin @('add', '-A') | Out-Null
    Run-Git $noOrigin @('commit', '-q', '-m', 'init') | Out-Null
    $noOriginResult = Invoke-Autopush $noOrigin
    Check-Equal 1 $noOriginResult.ExitCode 'repo without origin exits 1'
    Check-Contains $noOriginResult.Stderr "has no 'origin' remote configured" 'repo without origin error is clear'

    # Detached HEAD
    Run-Git $work @('checkout', '-q', '--detach') | Out-Null
    $detached = Invoke-Autopush $work
    Check-Equal 1 $detached.ExitCode 'detached HEAD exits 1'
    Check-Contains $detached.Stderr 'detached HEAD state' 'detached HEAD error is clear'
    Run-Git $work @('checkout', '-q', 'main') | Out-Null

    $headBeforeMixed = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()

    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'modified'
    Remove-Item -LiteralPath (Join-Path $work 'delete me.txt')
    Run-Git $work @('rm', '-q', '--', 'staged delete.txt') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'staged only.txt') -Value 'staged change'
    Run-Git $work @('add', '--', 'staged only.txt') | Out-Null
    Run-Git $work @('mv', '--', 'rename old.txt', 'rename new.txt') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'z-staged.txt') -Value 'pre-staged change'
    Run-Git $work @('add', '--', 'z-staged.txt') | Out-Null

    Set-Content -LiteralPath (Join-Path $work 'untracked file.txt') -Value 'u'
    Set-Content -LiteralPath (Join-Path $work "quote'file.txt") -Value 'q'
    Set-Content -LiteralPath (Join-Path $work '$dollar.txt') -Value 'd'
    Set-Content -LiteralPath (Join-Path $work 'glob[a].txt') -Value 'glob'
    Set-Content -LiteralPath (Join-Path $work 'globa.txt') -Value 'globa'
    Set-Content -LiteralPath (Join-Path $work '-leading.txt') -Value 'dash'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'sub dir') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'sub dir\space name.js') -Value 's'

    $mixed = Invoke-Autopush $work
    Check-Equal 0 $mixed.ExitCode 'mixed autopush exits 0'
    Check-Equal '' $mixed.Stderr.Trim() 'mixed autopush writes no stderr'
    Check-Contains $mixed.Stdout '# Repository "work repo" | branch: main' 'autopush prints repository and branch'
    Check-Contains $mixed.Stdout '# Pending: 13 file(s)' 'autopush counts 13 files'
    Check-Contains $mixed.Stdout 'added 0, modified 4, deleted 2, untracked 7' 'autopush reports categories'
    Check-Contains $mixed.Stdout 'staged 4' 'autopush reports staged files'
    Check-Contains $mixed.Stdout 'tracked.txt: chore: update tracked.txt content' 'autopush confirms each proposed per-file message'
    Check-Contains $mixed.Stdout 'Autopush complete: 13 file(s), 13 commit(s), 13 push(es) to origin/main.' 'autopush final summary is correct'
    Check-Equal '13' ([string](Get-PushCount $origin)) 'each successful commit is pushed immediately'
    Check-Equal '0' (@($mixed.Stdout -split "`r?`n" | Where-Object { $_ -match '^  push    ' }).Count - 13) 'prints one push line per file'

    $statusAfterMixed = (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim()
    Check-Equal '' $statusAfterMixed 'working tree is clean after mixed autopush'

    $localHead = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $remoteHead = (& git --git-dir=$origin rev-parse refs/heads/main 2>$null | Out-String).Trim()
    Check-Equal $localHead $remoteHead 'remote branch matches local HEAD after autopush'

    $commitCount = (Run-Git $work @('rev-list', '--count', 'HEAD') | Out-String).Trim()
    Check-Equal '14' $commitCount 'created one commit per pending file'

    $log = (Run-Git $work @('log', '--format=%s') | Out-String)
    foreach ($message in @(
        'chore: update tracked.txt content',
        'refactor: remove delete me.txt',
        'refactor: remove staged delete.txt',
        'chore: update staged only.txt content',
        'refactor: rename rename old.txt to rename new.txt',
        'chore: update z-staged.txt content',
        'chore: add untracked file.txt',
        "chore: add quote'file.txt",
        'chore: add $dollar.txt',
        'chore: add glob[a].txt',
        'chore: add globa.txt',
        'chore: add -leading.txt',
        'chore: add space name.js'
    )) {
        Check-Contains $log $message "autopush created commit: $message"
    }

    $allHashes = @(Run-Git $work @('log', '--reverse', '--format=%H'))
    $firstNewHash = $allHashes[1]
    $firstNewNames = @(Run-Git $work @('show', '--pretty=format:', '--name-only', $firstNewHash) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Check-Equal '1' ([string]$firstNewNames.Count) 'first commit contains exactly one file'
    Check (-not ($firstNewNames -contains 'z-staged.txt')) 'pre-staged unrelated file is not swept into another commit'

    $globHash = @(Run-Git $work @('log', '--fixed-strings', '--grep=chore: add glob[a].txt', '--format=%H'))[0]
    $globNames = @(Run-Git $work @('show', '--pretty=format:', '--name-only', $globHash) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Check ($globNames -contains 'glob[a].txt') 'literal glob filename is committed'
    Check (-not ($globNames -contains 'globa.txt')) 'literal glob filename does not match another file'

    $renameCommits = ((Run-Git $work @('log', '--follow', '--format=%H', '--', 'rename new.txt') | Out-String).Trim() -split "`r?`n").Count
    Check-Equal '2' ([string]$renameCommits) 'rename-aware file history has 2 commits'

    $again = Invoke-Autopush $work
    Check-Equal 0 $again.ExitCode 'second run on clean repo exits 0'
    Check-Contains $again.Stdout 'is up to date.' 'second run reports up to date'
    Check-Equal '13' ([string](Get-PushCount $origin)) 'second clean run does not push'

    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'modified again'
    Set-Content -LiteralPath (Join-Path $work 'rename new.txt') -Value 'renamed modified'
    $secondChanges = Invoke-Autopush $work
    Check-Equal 0 $secondChanges.ExitCode 'second change run exits 0'
    Check-Contains $secondChanges.Stdout 'Autopush complete: 2 file(s), 2 commit(s), 2 push(es) to origin/main.' 'second change summary is correct'
    Check-Contains (Run-Git $work @('log', '--format=%s') | Out-String) 'chore: update tracked.txt content' 'modified file message is retained'
    Check-Contains (Run-Git $work @('log', '--format=%s') | Out-String) 'refactor: rename rename old.txt to rename new.txt' 'rename message is retained'
    Check-Equal '15' ([string](Get-PushCount $origin)) 'second change run pushes each commit'
    Check-Equal '16' ((Run-Git $work @('rev-list', '--count', 'HEAD') | Out-String).Trim()) 'second change run adds exactly two commits'

    # --- Current feature branch without upstream ---
    $mainHeadBeforeFeature = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    Run-Git $work @('checkout', '-q', '-b', 'feature/test') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'feature change'
    $feature = Invoke-Autopush $work
    Check-Equal 0 $feature.ExitCode 'feature branch autopush exits 0'
    Check-Contains $feature.Stdout 'Autopush complete: 1 file(s), 1 commit(s), 1 push(es) to origin/feature/test.' 'feature branch summary uses the current branch'
    Check-Contains (Run-Git $work @('log', '-1', '--format=%s') | Out-String) 'chore: update tracked.txt content' 'feature branch commit message is correct'
    $featureHead = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $featureRemote = (& git --git-dir=$origin rev-parse refs/heads/feature/test 2>$null | Out-String).Trim()
    Check-Equal $featureHead $featureRemote 'feature branch without upstream is pushed'
    Check-Equal $mainHeadBeforeFeature ((& git --git-dir=$origin rev-parse refs/heads/main 2>$null | Out-String).Trim()) 'feature push does not move main'
    Check-Equal '16' ([string](Get-PushCount $origin)) 'feature branch commit is pushed'
    Run-Git $work @('checkout', '-q', 'main') | Out-Null

    # --- Commit failure stops immediately ---
    $originFail = Join-Path $base 'origin-commit-fail.git'
    $workFail = Join-Path $base 'commit fail repo'
    New-BareOrigin $originFail
    New-WorkRepo $workFail $originFail
    Set-Content -LiteralPath (Join-Path $workFail 'a.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $workFail 'b-fail.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $workFail 'c.txt') -Value 'initial'
    New-InitialCommit $workFail
    Reset-PushCount $originFail
    Set-HookFile (Join-Path $workFail '.git\hooks\pre-commit') @'
#!/bin/sh
if git diff --cached --name-only | grep -q '^b-fail.txt$'; then
  echo 'simulated commit failure for b-fail.txt' >&2
  exit 1
fi
exit 0
'@

    Set-Content -LiteralPath (Join-Path $workFail 'a.txt') -Value 'changed a'
    Set-Content -LiteralPath (Join-Path $workFail 'b-fail.txt') -Value 'changed b'
    Set-Content -LiteralPath (Join-Path $workFail 'c.txt') -Value 'changed c'
    $commitFailure = Invoke-Autopush $workFail
    Check-Equal 1 $commitFailure.ExitCode 'commit failure exits 1'
    Check-Contains $commitFailure.Stderr "git commit failed for 'b-fail.txt'" 'commit failure identifies the file'
    Check-Contains $commitFailure.Stderr 'simulated commit failure' 'commit failure includes Git error output'
    Check-Contains $commitFailure.Stdout 'Autopush summary: 1 of 3 file(s) completed; 1 commit(s) created; 1 push(es) completed to origin/main.' 'commit failure summary is accurate'
    Check-Equal '1' ([string](Get-PushCount $originFail)) 'commit failure pushes only the successful file'
    Check-Contains (Run-Git $workFail @('log', '--format=%s') | Out-String) 'chore: update a.txt content' 'commit failure leaves successful commit'
    Check (-not ((Run-Git $workFail @('log', '--format=%s') | Out-String).Contains('Update c.txt'))) 'commit failure does not process later files'
    $failStatus = (Run-Git $workFail @('status', '--porcelain=v1') | Out-String)
    Check-Contains $failStatus 'b-fail.txt' 'failed file remains pending'
    Check-Contains $failStatus 'c.txt' 'later file remains pending'

    # --- Push failure stops after commit ---
    $originPushFail = Join-Path $base 'origin-push-fail.git'
    $workPushFail = Join-Path $base 'push fail repo'
    New-BareOrigin $originPushFail
    New-WorkRepo $workPushFail $originPushFail
    Set-Content -LiteralPath (Join-Path $workPushFail 'a.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $workPushFail 'b.txt') -Value 'initial'
    New-InitialCommit $workPushFail
    Reset-PushCount $originPushFail
    Set-HookFile (Join-Path $workPushFail '.git\hooks\pre-push') @'
#!/bin/sh
echo 'simulated push failure' >&2
exit 1
'@

    Set-Content -LiteralPath (Join-Path $workPushFail 'a.txt') -Value 'changed a'
    Set-Content -LiteralPath (Join-Path $workPushFail 'b.txt') -Value 'changed b'
    $pushFailure = Invoke-Autopush $workPushFail
    Check-Equal 1 $pushFailure.ExitCode 'push failure exits 1'
    Check-Contains $pushFailure.Stderr "git push origin main failed after committing 'a.txt'" 'push failure identifies the committed file'
    Check-Contains $pushFailure.Stderr 'simulated push failure' 'push failure includes Git error output'
    Check-Contains $pushFailure.Stdout 'Autopush summary: 0 of 2 file(s) completed; 1 commit(s) created; 0 push(es) completed to origin/main.' 'push failure summary is accurate'
    Check-Equal '0' ([string](Get-PushCount $originPushFail)) 'push failure does not push to origin'
    Check-Equal 'Initial commit' ((& git --git-dir=$originPushFail log -1 --format=%s refs/heads/main 2>$null | Out-String).Trim()) 'push failure leaves remote at previous commit'
    Check-Contains (Run-Git $workPushFail @('log', '-1', '--format=%s') | Out-String) 'chore: update a.txt content' 'push failure leaves the local commit'
    Check-Contains (Run-Git $workPushFail @('status', '--porcelain=v1') | Out-String) 'b.txt' 'push failure does not process later files'

    # --- Stale change stops before processing the next file ---
    $originStale = Join-Path $base 'origin-stale.git'
    $workStale = Join-Path $base 'stale repo'
    New-BareOrigin $originStale
    New-WorkRepo $workStale $originStale
    Set-Content -LiteralPath (Join-Path $workStale 'a.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $workStale 'b.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $workStale 'c.txt') -Value 'initial'
    New-InitialCommit $workStale
    Reset-PushCount $originStale
    Set-HookFile (Join-Path $workStale '.git\hooks\post-commit') @'
#!/bin/sh
if [ ! -f new-after.txt ]; then
  echo 'appeared during autopush' > new-after.txt
fi
exit 0
'@

    Set-Content -LiteralPath (Join-Path $workStale 'a.txt') -Value 'changed a'
    Set-Content -LiteralPath (Join-Path $workStale 'b.txt') -Value 'changed b'
    Set-Content -LiteralPath (Join-Path $workStale 'c.txt') -Value 'changed c'
    $stale = Invoke-Autopush $workStale
    Check-Equal 1 $stale.ExitCode 'stale changes stop autopush'
    Check-Contains $stale.Stderr 'pending changes changed while autopush was running' 'stale stop has a clear error'
    Check-Contains $stale.Stdout 'Autopush summary: 1 of 3 file(s) completed; 1 commit(s) created; 1 push(es) completed to origin/main.' 'stale stop summary is accurate'
    Check-Equal '1' ([string](Get-PushCount $originStale)) 'stale stop pushes only the completed file'
    Check (-not ((Run-Git $workStale @('log', '--format=%s') | Out-String).Contains('Update b.txt'))) 'stale stop does not commit the next file'
    Check (Test-Path -LiteralPath (Join-Path $workStale 'new-after.txt')) 'stale test created its concurrent change'
    Check-Contains (Run-Git $workStale @('status', '--porcelain=v1') | Out-String) 'b.txt' 'stale stop leaves later file pending'

    # --- Empty repository (unborn branch) ---
    $originEmpty = Join-Path $base 'origin-empty.git'
    $workEmpty = Join-Path $base 'empty repo'
    New-BareOrigin $originEmpty
    New-WorkRepo $workEmpty $originEmpty
    Set-Content -LiteralPath (Join-Path $workEmpty 'first.txt') -Value 'first'
    $empty = Invoke-Autopush $workEmpty
    Check-Equal 0 $empty.ExitCode 'autopush works in a repo with no commits'
    Check-Contains $empty.Stdout 'Autopush complete: 1 file(s), 1 commit(s), 1 push(es) to origin/main.' 'unborn repo summary is correct'
    Check-Contains (Run-Git $workEmpty @('log', '--format=%s') | Out-String) 'chore: add first.txt' 'unborn repo gets a Conventional Commit message'
    Check-Equal '1' ([string](Get-PushCount $originEmpty)) 'unborn repo push reaches origin'
    Check (-not [string]::IsNullOrWhiteSpace((& git --git-dir=$originEmpty rev-parse refs/heads/main 2>$null | Out-String))) 'unborn repo creates remote main'

    # --- Non-ASCII filename ---
    $originUnicode = Join-Path $base 'origin-unicode.git'
    $workUnicode = Join-Path $base 'unicode repo'
    New-BareOrigin $originUnicode
    New-WorkRepo $workUnicode $originUnicode
    Set-Content -LiteralPath (Join-Path $workUnicode 'seed.txt') -Value 'seed'
    New-InitialCommit $workUnicode
    Reset-PushCount $originUnicode
    $unicodeName = 'caf' + [char]0x00E9 + '.txt'
    Set-Content -LiteralPath (Join-Path $workUnicode $unicodeName) -Value 'unicode'
    $unicodeRun = Invoke-Autopush $workUnicode
    Check-Equal 0 $unicodeRun.ExitCode 'non-ASCII filename autopush exits 0'
    Check-Contains (Run-Git $workUnicode @('log', '--format=%s') | Out-String) ("chore: add $unicodeName") 'non-ASCII filename commit message is correct'
    Check-Equal '' ((Run-Git $workUnicode @('status', '--porcelain=v1') | Out-String).Trim()) 'non-ASCII filename leaves a clean tree'
    Check-Equal '1' ([string](Get-PushCount $originUnicode)) 'non-ASCII filename is pushed'

    # --- Unknown argument ---
    $unknown = Invoke-Autopush $work -Arguments 'autopush --bogus'
    Check-Equal 1 $unknown.ExitCode 'unknown argument exits 1'
    Check-Contains $unknown.Stderr 'unknown argument' 'unknown argument is rejected'

    # --- Combined diff message and single push ---
    $originCombined = Join-Path $base 'origin-combined.git'
    $workCombined = Join-Path $base 'combined repo'
    New-BareOrigin $originCombined
    New-WorkRepo $workCombined $originCombined
    Set-Content -LiteralPath (Join-Path $workCombined 'app.js') -Value 'const loginRedirect = "/old"'
    Set-Content -LiteralPath (Join-Path $workCombined 'style.css') -Value 'color: red'
    New-InitialCommit $workCombined
    Reset-PushCount $originCombined
    Set-Content -LiteralPath (Join-Path $workCombined 'app.js') -Value 'const loginRedirect = "/home"'
    Set-Content -LiteralPath (Join-Path $workCombined 'style.css') -Value 'color: blue'
    $combined = Invoke-Autopush $workCombined -Arguments 'autopush --combined'
    Check-Equal 0 $combined.ExitCode 'combined autopush succeeds'
    Check-Contains $combined.Stdout 'combined: fix: correct login redirect; update style.css content' 'combined message summarizes changed diffs'
    Check-Contains (Run-Git $workCombined @('log', '-1', '--format=%s') | Out-String) 'fix: correct login redirect; update style.css content' 'combined message is committed'
    Check-Equal '1' ([string](Get-PushCount $originCombined)) 'combined autopush pushes once'
    Check-Equal '2' ((Run-Git $workCombined @('rev-list', '--count', 'HEAD') | Out-String).Trim()) 'combined autopush creates one commit'

    # --- Binary add, update, and delete use content-free subjects ---
    $originBinary = Join-Path $base 'origin-binary.git'
    $workBinary = Join-Path $base 'binary repo'
    New-BareOrigin $originBinary
    New-WorkRepo $workBinary $originBinary
    [System.IO.File]::WriteAllBytes((Join-Path $workBinary 'updated.bin'), [byte[]](1, 0, 3))
    [System.IO.File]::WriteAllBytes((Join-Path $workBinary 'removed.bin'), [byte[]](4, 0, 6))
    New-InitialCommit $workBinary
    Reset-PushCount $originBinary
    [System.IO.File]::WriteAllBytes((Join-Path $workBinary 'updated.bin'), [byte[]](7, 0, 9))
    Remove-Item -LiteralPath (Join-Path $workBinary 'removed.bin')
    [System.IO.File]::WriteAllBytes((Join-Path $workBinary 'added.bin'), [byte[]](10, 0, 12))
    $binary = Invoke-Autopush $workBinary
    Check-Equal 0 $binary.ExitCode 'binary autopush succeeds'
    $binaryLog = Run-Git $workBinary @('log', '--format=%s') | Out-String
    Check-Contains $binaryLog 'chore: update binary asset updated.bin' 'binary modification is identified'
    Check-Contains $binaryLog 'chore: remove binary asset removed.bin' 'binary deletion is identified'
    Check-Contains $binaryLog 'chore: add binary asset added.bin' 'binary addition is identified'
}
catch {
    $script:fail++
    $failures.Add('unexpected exception')
    Write-Output 'FAIL: unexpected exception'
    Write-Output ($_ | Out-String)
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) {
    Write-Output 'Failures:'
    foreach ($failure in $failures) {
        Write-Output " - $failure"
    }
    exit 1
}
exit 0
