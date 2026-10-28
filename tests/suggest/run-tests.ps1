$ErrorActionPreference = 'Continue'
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

function Invoke-Suggest {
    param([string]$WorkingDirectory, [string]$Arguments = 'suggest')
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

function Get-ChangedLines {
    param([string]$Text)
    @($Text -split "`r?`n" | Where-Object { $_ -match '^git ' })
}

$base = Join-Path $env:TEMP ('git-suggest-tests-' + [guid]::NewGuid().ToString('N'))
$origin = Join-Path $base 'origin.git'
$work = Join-Path $base 'work repo'
$noOrigin = Join-Path $base 'no-origin'
$notRepo = Join-Path $base 'not-a-repo'

try {
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    New-Item -ItemType Directory -Force -Path $notRepo | Out-Null

    & git init --bare -q $origin
    if ($LASTEXITCODE -ne 0) { throw 'bare init failed' }

    & git init -q -b main $work
    if ($LASTEXITCODE -ne 0) { throw 'work init failed' }
    Run-Git $work @('config', 'user.email', 'test@example.com') | Out-Null
    Run-Git $work @('config', 'user.name', 'Test') | Out-Null
    Run-Git $work @('remote', 'add', 'origin', $origin) | Out-Null

    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'delete me.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'staged delete.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'staged only.txt') -Value 'initial'
    Set-Content -LiteralPath (Join-Path $work 'rename old.txt') -Value 'initial'
    Run-Git $work @('add', '-A') | Out-Null
    Run-Git $work @('commit', '-q', '-m', 'Initial commit') | Out-Null
    Run-Git $work @('push', '-q', '-u', 'origin', 'main') | Out-Null

    # Clean repository
    $clean = Invoke-Suggest $work
    Check-Equal 0 $clean.ExitCode 'clean repo exit code is 0'
    Check-Equal 'Repository "work repo" is up to date.' $clean.Stdout.Trim() 'clean repo prints exact up-to-date line'
    Check-Equal '' $clean.Stderr.Trim() 'clean repo writes no stderr'

    # Outside a repository
    $outside = Invoke-Suggest $notRepo
    Check-Equal 1 $outside.ExitCode 'outside a repository exits 1'
    Check-Contains $outside.Stderr 'not inside a Git working tree' 'outside a repository shows clear error'

    # Missing origin
    & git init -q -b main $noOrigin
    if ($LASTEXITCODE -ne 0) { throw 'no-origin init failed' }
    Run-Git $noOrigin @('config', 'user.email', 'test@example.com') | Out-Null
    Run-Git $noOrigin @('config', 'user.name', 'Test') | Out-Null
    Set-Content -LiteralPath (Join-Path $noOrigin 'a.txt') -Value 'a'
    Run-Git $noOrigin @('add', '-A') | Out-Null
    Run-Git $noOrigin @('commit', '-q', '-m', 'init') | Out-Null
    $missingOrigin = Invoke-Suggest $noOrigin
    Check-Equal 1 $missingOrigin.ExitCode 'repo without origin exits 1'
    Check-Contains $missingOrigin.Stderr "has no 'origin' remote configured" 'repo without origin shows clear error'

    # Detached HEAD
    Run-Git $work @('checkout', '-q', '--detach') | Out-Null
    $detached = Invoke-Suggest $work
    Check-Equal 1 $detached.ExitCode 'detached HEAD exits 1'
    Check-Contains $detached.Stderr 'detached HEAD state' 'detached HEAD shows clear error'
    Run-Git $work @('checkout', '-q', 'main') | Out-Null

    # Make every kind of change.
    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'modified'
    Remove-Item -LiteralPath (Join-Path $work 'delete me.txt')
    Run-Git $work @('rm', '-q', '--', 'staged delete.txt') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'staged only.txt') -Value 'staged change'
    Run-Git $work @('add', '--', 'staged only.txt') | Out-Null
    Run-Git $work @('mv', '--', 'rename old.txt', 'rename new.txt') | Out-Null

    Set-Content -LiteralPath (Join-Path $work 'untracked file.txt') -Value 'u'
    Set-Content -LiteralPath (Join-Path $work "quote'file.txt") -Value 'q'
    Set-Content -LiteralPath (Join-Path $work '$dollar.txt') -Value 'd'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'sub dir') | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'sub dir\space name.js') -Value 's'

    $headBefore = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $statusBefore = (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim()
    $result = Invoke-Suggest $work
    $headAfter = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $statusAfter = (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim()

    Check-Equal 0 $result.ExitCode 'dirty repo exits 0'
    Check-Equal $headBefore $headAfter 'git suggest does not change HEAD'
    Check-Equal $statusBefore $statusAfter 'git suggest does not change status'
    Check-Equal '' $result.Stderr.Trim() 'dirty repo writes no stderr'

    $out = $result.Stdout
    Check-Contains $out '# Repository "work repo" | branch: main' 'prints repo name and branch'
    Check-Contains $out '# Changes: 9 file(s)' 'counts all changed files'
    Check-Contains $out 'added 0, modified 3, deleted 2, untracked 4' 'reports change categories'
    Check-Contains $out 'staged 3' 'reports staged files'
    Check-Contains $out '# Suggested commands only; nothing was executed.' 'states commands are not executed'

    $expectedLines = @(
        "git add -- 'tracked.txt'",
        "git commit -m 'chore: update tracked.txt content' -- 'tracked.txt'",
        "git add -A -- 'delete me.txt'",
        "git commit -m 'refactor: remove delete me.txt' -- 'delete me.txt'",
        "git commit -m 'refactor: remove staged delete.txt' -- 'staged delete.txt'",
        "git commit -m 'chore: update staged only.txt content' -- 'staged only.txt'",
        "git commit -m 'refactor: rename rename old.txt to rename new.txt' -- 'rename old.txt' 'rename new.txt'",
        "git add -- 'untracked file.txt'",
        "git commit -m 'chore: add untracked file.txt' -- 'untracked file.txt'",
        "git add -- 'quote''file.txt'",
        "git commit -m 'chore: add quote''file.txt' -- 'quote''file.txt'",
        "git add -- '`$dollar.txt'",
        "git commit -m 'chore: add `$dollar.txt' -- '`$dollar.txt'",
        "git add -- 'sub dir/space name.js'",
        "git commit -m 'chore: add space name.js' -- 'sub dir/space name.js'",
        'git push origin main'
    )

    foreach ($line in $expectedLines) {
        Check-Contains $out $line "prints: $line"
    }

    $changedLines = Get-ChangedLines $out
    Check (-not ($changedLines -contains "git add -- 'staged only.txt'")) 'omits redundant add for staged modification'
    Check (-not ($changedLines -contains "git add -A -- 'staged delete.txt'")) 'omits failing add for staged deletion'
    Check (-not ($changedLines -contains "git add -- 'rename new.txt'")) 'omits redundant add for staged rename'
    Check ($changedLines[-1] -eq 'git push origin main') 'prints push as the final command'

    # Execute the printed commands exactly as PowerShell would.
    foreach ($line in $changedLines) {
        Push-Location -LiteralPath $work
        $commandOutput = Invoke-Expression $line 2>&1
        $commandExit = $LASTEXITCODE
        Pop-Location
        Check-Equal 0 $commandExit "generated command succeeds: $line"
        if ($commandExit -ne 0) {
            Write-Output "  output: $($commandOutput | Out-String)"
        }
    }

    $statusClean = (Run-Git $work @('status', '--porcelain=v1') | Out-String).Trim()
    Check-Equal '' $statusClean 'working tree is clean after running generated commands'

    $afterRun = Invoke-Suggest $work
    Check-Equal 'Repository "work repo" is up to date.' $afterRun.Stdout.Trim() 'prints up-to-date after generated commands run'

    $commitCount = ((Run-Git $work @('rev-list', '--count', 'HEAD') | Out-String).Trim())
    Check-Equal '10' $commitCount 'created one commit per changed file'

    $log = (Run-Git $work @('log', '--format=%s') | Out-String)
    foreach ($message in @(
        'chore: update tracked.txt content',
        'refactor: remove delete me.txt',
        'refactor: remove staged delete.txt',
        'chore: update staged only.txt content',
        'refactor: rename rename old.txt to rename new.txt',
        'chore: add untracked file.txt',
        "chore: add quote'file.txt",
        'chore: add $dollar.txt',
        'chore: add space name.js'
    )) {
        Check-Contains $log $message "commit exists: $message"
    }

    $localHead = (Run-Git $work @('rev-parse', 'HEAD') | Out-String).Trim()
    $remoteHead = (& git --git-dir=$origin rev-parse refs/heads/main 2>$null | Out-String).Trim()
    Check-Equal $localHead $remoteHead 'pushed commit matches local HEAD'

    $trackedCommits = ((Run-Git $work @('log', '--follow', '--format=%H', '--', 'tracked.txt') | Out-String).Trim() -split "`r?`n").Count
    Check-Equal '2' ([string]$trackedCommits) 'tracked file has 2 successful commits'
    $newNameCommits = ((Run-Git $work @('log', '--follow', '--format=%H', '--', 'rename new.txt') | Out-String).Trim() -split "`r?`n").Count
    Check-Equal '2' ([string]$newNameCommits) 'rename-aware file history has 2 commits'
    $deletedCommits = ((Run-Git $work @('log', '--follow', '--format=%H', '--', 'delete me.txt') | Out-String).Trim() -split "`r?`n").Count
    Check-Equal '2' ([string]$deletedCommits) 'deleted file history has 2 commits'

    # Persistent count after successful commits.
    Set-Content -LiteralPath (Join-Path $work 'tracked.txt') -Value 'modified again'
    Set-Content -LiteralPath (Join-Path $work 'rename new.txt') -Value 'renamed modified'
    $next = Invoke-Suggest $work
    Check-Contains $next.Stdout "git commit -m 'chore: update tracked.txt content' -- 'tracked.txt'" 'modified file message is diff based'
    Check-Contains $next.Stdout "git commit -m 'chore: update rename new.txt content' -- 'rename new.txt'" 'renamed file message uses its current diff'

    Set-Content -LiteralPath (Join-Path $work 'responsive-nav.css') -Value '@media (max-width: 600px) { .navigation { display: flex } }'
    $semantic = Invoke-Suggest $work
    Check-Contains $semantic.Stdout "git commit -m 'feat: add responsive navigation'" 'suggest describes responsive navigation from its diff'
    $combinedSuggestion = Invoke-Suggest $work -Arguments 'suggest --combined'
    Check-Equal '1' ([string](@($combinedSuggestion.Stdout -split "`r?`n" | Where-Object { $_ -match '^git commit -m ' }).Count)) 'combined suggest prints one commit'
    Check-Contains $combinedSuggestion.Stdout 'feat: ' 'combined suggest uses a Conventional Commit type'
    Check-Contains $combinedSuggestion.Stdout 'responsive navigation' 'combined suggest summarizes changed content'

    $redirectPath = Join-Path $work 'redirect-message.js'
    Set-Content -LiteralPath $redirectPath -Value 'const loginRedirect = "/signin";'
    $redirectMessage = Invoke-Suggest $work
    Check-Contains $redirectMessage.Stdout "git commit -m 'fix: correct login redirect'" 'redirect diff gets a specific fix subject'
    Remove-Item -LiteralPath $redirectPath

    $a11yPath = Join-Path $work 'a11y-message.css'
    Set-Content -LiteralPath $a11yPath -Value '.control:focus-visible { outline: 2px solid blue }'
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'fix: improve keyboard accessibility'" 'focus-visible diff gets an accessibility subject'
    Remove-Item -LiteralPath $a11yPath

    $validationPath = Join-Path $work 'validation-message.js'
    Set-Content -LiteralPath $validationPath -Value 'const validationError = validateInput(value);'
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'fix: improve input validation'" 'validation diff gets a fix subject'
    Remove-Item -LiteralPath $validationPath

    $symbolPath = Join-Path $work 'symbol-message.js'
    Set-Content -LiteralPath $symbolPath -Value 'function initializeMenu() { return true; }'
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'feat: add initializeMenu'" 'new function diff identifies its symbol'
    Remove-Item -LiteralPath $symbolPath

    $genericPath = Join-Path $work 'generic-message.txt'
    Set-Content -LiteralPath $genericPath -Value 'plain content without a feature signal'
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'chore: add generic-message.txt'" 'unclassified text addition uses a chore fallback'
    Remove-Item -LiteralPath $genericPath

    $environmentPath = Join-Path $work '.env.local'
    Set-Content -LiteralPath $environmentPath -Value 'API_KEY=DO_NOT_PRINT_7c1a'
    $environmentSuggestion = Invoke-Suggest $work
    Check-Contains $environmentSuggestion.Stdout "git commit -m 'chore: add configuration'" 'sensitive filename is sanitized in the subject'
    Check (-not $environmentSuggestion.Stdout.Contains('DO_NOT_PRINT_7c1a')) 'secret-like file content is not printed'
    Remove-Item -LiteralPath $environmentPath

    $deletedPath = Join-Path $work 'removed-feature.js'
    Set-Content -LiteralPath $deletedPath -Value 'function removedFeature() { return true; }'
    Run-Git $work @('add', '--', 'removed-feature.js') | Out-Null
    Run-Git $work @('commit', '-q', '-m', 'seed deletion fixture') | Out-Null
    Remove-Item -LiteralPath $deletedPath
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'refactor: remove removed-feature.js'" 'deleted file gets a removal subject'

    $contentPath = Join-Path $work 'private-content.txt'
    Set-Content -LiteralPath $contentPath -Value 'CONTENT_SENTINEL_3c92 must stay out of preview output'
    $contentSuggestion = Invoke-Suggest $work
    Check (-not $contentSuggestion.Stdout.Contains('CONTENT_SENTINEL_3c92')) 'suggest never prints diff contents'
    Remove-Item -LiteralPath $contentPath

    $stagedPath = Join-Path $work 'staged-menu.js'
    Set-Content -LiteralPath $stagedPath -Value 'function initializeStagedMenu() { return true; }'
    Run-Git $work @('add', '--', 'staged-menu.js') | Out-Null
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'feat: add initializeStagedMenu'" 'staged addition is analyzed from its diff'
    Run-Git $work @('rm', '--cached', '-q', '--', 'staged-menu.js') | Out-Null
    Remove-Item -LiteralPath $stagedPath

    $modifiedSymbolPath = Join-Path $work 'modified-symbol.js'
    Set-Content -LiteralPath $modifiedSymbolPath -Value 'function modifyFeature() { return 1; }'
    Run-Git $work @('add', '--', 'modified-symbol.js') | Out-Null
    Run-Git $work @('commit', '-q', '-m', 'seed symbol fixture') | Out-Null
    Set-Content -LiteralPath $modifiedSymbolPath -Value 'function modifyFeature() { return 2; }'
    Check-Contains (Invoke-Suggest $work).Stdout "git commit -m 'refactor: update modifyFeature behavior'" 'modified function diff names its symbol'
    Run-Git $work @('checkout', '--', 'modified-symbol.js') | Out-Null

    # Empty repository with an origin and an untracked file.
    $empty = Join-Path $base 'empty repo'
    & git init -q -b main $empty
    if ($LASTEXITCODE -ne 0) { throw 'empty repo init failed' }
    Run-Git $empty @('config', 'user.email', 'test@example.com') | Out-Null
    Run-Git $empty @('config', 'user.name', 'Test') | Out-Null
    Run-Git $empty @('remote', 'add', 'origin', $origin) | Out-Null
    Set-Content -LiteralPath (Join-Path $empty 'first.txt') -Value 'first'
    $emptyResult = Invoke-Suggest $empty
    Check-Equal 0 $emptyResult.ExitCode 'repo with no commits exits 0'
    Check-Contains $emptyResult.Stdout "git commit -m 'chore: add first.txt' -- 'first.txt'" 'new file in repo with no commits gets a Conventional Commit message'
}
catch {
    $script:fail++
    $failures.Add('unexpected exception')
    Write-Output "FAIL: unexpected exception"
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
