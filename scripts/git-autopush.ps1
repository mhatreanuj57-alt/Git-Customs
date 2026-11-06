$ErrorActionPreference = 'Continue'

if ($args -contains '--help' -or $args -contains '-h') {
    Write-Output 'Usage: git autopush [--combined]'
    Write-Output ''
    Write-Output 'Re-detects the pending changes reported by git suggest, then stages,'
    Write-Output 'commits, and pushes each file individually. --combined creates one commit.'
    Write-Output 'It stops if anything fails or if pending changes change during the run.'
    Write-Output 'Detects the branch push remote, checks for remote updates, and requires confirmation before changes.'
    Write-Output 'Never force-pushes; if the remote is ahead, sync with git pull --rebase and rerun.'
    exit 0
}

$combined = $args -contains '--combined'
$unknown = @($args | Where-Object { $_ -ne '--combined' })
if ($unknown.Count -gt 0) {
    [Console]::Error.WriteLine("git autopush: unknown argument(s): $($unknown -join ' ')")
    exit 1
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("git autopush: $Message")
    exit 1
}

$corePath = Join-Path $PSScriptRoot 'git-suggest-core.ps1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    Fail "missing required file: $corePath"
}

try {
    . $corePath
}
catch {
    Fail "could not load the shared detection code: $($_.Exception.Message)"
}

function Get-AutopushTarget {
    param($Context)
    $branchConfig = 'branch.' + $Context.Branch + '.'
    $remote = ''
    foreach ($key in @($branchConfig + 'pushRemote', 'remote.pushDefault')) {
        $value = Invoke-GitDetect @('-C', $Context.RepoRoot, 'config', '--get', $key)
        if ($value.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($value.Output -join '').Trim())) { $remote = ($value.Output -join '').Trim(); break }
    }
    if ([string]::IsNullOrWhiteSpace($remote)) {
        $upstream = Invoke-GitDetect @('-C', $Context.RepoRoot, 'for-each-ref', '--format=%(upstream:remotename)', ('refs/heads/' + $Context.Branch))
        if ($upstream.ExitCode -eq 0) { $remote = ($upstream.Output -join '').Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($remote)) { $remote = 'origin' }
    $remoteUrl = Invoke-GitDetect @('-C', $Context.RepoRoot, 'remote', 'get-url', $remote)
    if ($remoteUrl.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($remoteUrl.Output -join '').Trim())) { throw "remote '$remote' is not configured." }
    $mergeRef = Invoke-GitDetect @('-C', $Context.RepoRoot, 'config', '--get', ($branchConfig + 'merge'))
    $remoteRef = if ($mergeRef.ExitCode -eq 0 -and ($mergeRef.Output -join '').Trim().StartsWith('refs/heads/')) { ($mergeRef.Output -join '').Trim() } else { 'refs/heads/' + $Context.Branch }
    [pscustomobject]@{ Name = $remote; Url = ($remoteUrl.Output -join '').Trim(); Ref = $remoteRef; Branch = $remoteRef.Substring('refs/heads/'.Length) }
}

function Test-AutopushRemote {
    param($Context, $Target)
    $remoteRef = $Target.Ref
    $remoteHead = Invoke-GitDetect @('-C', $Context.RepoRoot, 'ls-remote', '--heads', $Target.Name, $remoteRef)
    if ($remoteHead.ExitCode -ne 0) { throw ("could not check remote '$($Target.Name)' for updates: " + ($remoteHead.Output -join ' ')) }
    if (@($remoteHead.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) { return $false }
    $fetch = Invoke-GitAction @('-C', $Context.RepoRoot, 'fetch', '--no-tags', $Target.Name, $remoteRef)
    if ($fetch.ExitCode -ne 0) { throw ("could not fetch '$($Target.Name)/$($Target.Branch)': " + (Format-GitFailure $fetch)) }
    if (-not $Context.HasHead) { throw "remote '$($Target.Name)/$($Target.Branch)' has commits but the local branch has no commit. Sync it before running autopush." }
    $remoteIsAncestor = Invoke-GitDetect @('-C', $Context.RepoRoot, 'merge-base', '--is-ancestor', 'FETCH_HEAD', 'HEAD')
    if ($remoteIsAncestor.ExitCode -eq 0) { return $true }
    $localIsAncestor = Invoke-GitDetect @('-C', $Context.RepoRoot, 'merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD')
    if ($localIsAncestor.ExitCode -eq 0) { throw "remote '$($Target.Name)/$($Target.Branch)' has new commits. Sync safely with 'git pull --rebase $($Target.Name) $($Target.Branch)', resolve any conflicts, then rerun git autopush." }
    throw "local branch and remote '$($Target.Name)/$($Target.Branch)' have diverged. Sync safely with 'git pull --rebase $($Target.Name) $($Target.Branch)', resolve any conflicts, then rerun git autopush. No force-push was attempted."
}

function Get-AutopushAnalysis {
    param($Context, $Suggestion)
    $paths = if ($Suggestion.OldPath) { @($Suggestion.OldPath, $Suggestion.Path) } else { @($Suggestion.Path) }
    $gitArgs = @('-C', $Context.RepoRoot, 'diff', '--no-ext-diff', '--unified=0')
    if ($Context.HasHead) { $gitArgs += @('HEAD', '--') } else { $gitArgs += @('--') }
    $gitArgs += $paths
    $diff = Invoke-GitDetect $gitArgs
    $text = $diff.Output -join "`n"
    $binary = $text -match '(?m)^Binary files '
    if ($Suggestion.IsUntracked) {
        $file = Join-Path $Context.RepoRoot $Suggestion.Path
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($file)
            $binary = $binary -or ($bytes -contains 0)
            if (-not $binary) { $text = (([IO.File]::ReadAllText($file) -split "`r?`n") | ForEach-Object { "+$_" }) -join "`n" }
        }
    }
    $fileName = [IO.Path]::GetFileName($Suggestion.Path)
    if ($fileName -match '(?i)(secret|credential|token|password|\.env)') { $fileName = 'configuration' }
    if ($Suggestion.IsRename) { return [pscustomobject]@{ Summary = "Renames '$($Suggestion.OldPath)' to '$($Suggestion.Path)'."; Message = "refactor: rename $($Suggestion.OldPath) to $($Suggestion.Path)" } }
    if ($binary) {
        if ($Suggestion.IsDeleted) { return [pscustomobject]@{ Summary = 'Removes a binary file.'; Message = "chore: remove binary asset $fileName" } }
        if ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') { return [pscustomobject]@{ Summary = 'Adds a binary file.'; Message = "chore: add binary asset $fileName" } }
        return [pscustomobject]@{ Summary = 'Updates a binary file.'; Message = "chore: update binary asset $fileName" }
    }
    $added = @($text -split "`r?`n" | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' })
    $removed = @($text -split "`r?`n" | Where-Object { $_ -match '^-' -and $_ -notmatch '^---' })
    $changes = ($added + $removed) -join "`n"
    $summary = 'Changes text; purpose is unclear from the diff.'
    $message = 'chore: update repository content'
    if ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') { $summary = 'Adds text content; purpose is unclear from the diff.'; $message = 'chore: add repository content' }
    if ($Suggestion.IsDeleted) { $summary = 'Removes content; purpose is unclear from the diff.'; $message = 'chore: remove repository content' }
    if ($changes -match '(?i)(@media|breakpoint|responsive)' -and $changes -match '(?i)(nav|menu|header)') { $summary = 'Adds or updates responsive navigation styles.'; $message = 'feat: add responsive navigation' }
    elseif ($changes -match '(?i)(loginRedirect|returnUrl|callbackUrl|redirect)' -and $changes -match '(?i)(login|signin|account|redirect)') { $summary = 'Changes login redirect handling.'; $message = 'fix: correct login redirect' }
    elseif ($changes -match '(?i)(focus-visible|aria-|keyboard|tabindex)') { $summary = 'Changes keyboard or assistive-technology interaction.'; $message = 'fix: improve keyboard accessibility' }
    elseif ($changes -match '(?i)(validate|validation|invalid)') { $summary = 'Changes input validation behavior.'; $message = 'fix: improve input validation' }
    elseif ($changes -match '(?i)(?:function|def|class)\s+([A-Za-z][A-Za-z0-9_-]{1,40})') {
        $symbol = [regex]::Match($changes, '(?i)(?:function|def|class)\s+([A-Za-z][A-Za-z0-9_-]{1,40})').Groups[1].Value
        if ($Suggestion.IsDeleted) { $summary = "Removes the $symbol implementation."; $message = "refactor: remove $symbol" }
        elseif ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') { $summary = "Adds the $symbol implementation."; $message = "feat: add $symbol" }
        else { $summary = "Changes the $symbol implementation."; $message = "refactor: update $symbol behavior" }
    } elseif ($Suggestion.Path -match '(?i)(^|[/\\])README(?:\.[^/\\]+)?$' -and $added.Count -gt 0) { $summary = 'Updates project documentation.'; $message = 'docs: update project documentation' }
    elseif ($Suggestion.Path -match '(?i)(^|[/\\])tests?[/\\]|\.(test|spec)\.' -and $changes) { $summary = 'Changes automated test coverage.'; $message = 'test: update automated coverage' }
    elseif ($added.Count -gt 0 -and $removed.Count -eq 0) { $summary = 'Adds content; purpose is unclear from the changed lines.'; $message = 'chore: add repository content' }
    elseif ($removed.Count -gt 0 -and $added.Count -eq 0) { $summary = 'Removes content; purpose is unclear from the changed lines.'; $message = 'chore: remove repository content' }
    [pscustomobject]@{ Summary = $summary; Message = $message }
}

function Set-AutopushAnalysis {
    param($Context, $Plan)
    foreach ($suggestion in @($Plan.Suggestions)) {
        $analysis = Get-AutopushAnalysis $Context $suggestion
        $suggestion | Add-Member -NotePropertyName Summary -NotePropertyValue $analysis.Summary -Force
        $suggestion | Add-Member -NotePropertyName Message -NotePropertyValue $analysis.Message -Force
        $suggestion | Add-Member -NotePropertyName CommitArguments -NotePropertyValue ([string[]](@('--literal-pathspecs', '-C', $Context.RepoRoot, 'commit', '-m', $analysis.Message, '--') + $suggestion.CommitPaths)) -Force
        $quotedMessage = ConvertTo-PowerShellLiteral $analysis.Message
        $quotedPaths = ($suggestion.CommitPaths | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ' '
        $suggestion | Add-Member -NotePropertyName DisplayCommitCommand -NotePropertyValue "git commit -m $quotedMessage -- $quotedPaths" -Force
    }
}

function Format-GitFailure {
    param([Parameter(Mandatory = $true)]$Result)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($Result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $lines.Add([string]$line)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) {
        $lines.Add(([string]$Result.Error).TrimEnd())
    }

    if ($lines.Count -eq 0) {
        return 'Git did not provide an error message.'
    }

    return ($lines -join "`n")
}

$script:autoPushTotal = 0
$script:autoPushCompleted = 0
$script:autoPushCommits = 0
$script:autoPushPushes = 0
$script:autoPushBranch = ''
$script:autoPushRepoName = ''
$script:autoPushRemote = ''
$script:autoPushRemoteBranch = ''

function Write-AutopushSummary {
    Write-Output ''
    Write-Output ("Autopush summary: {0} of {1} file(s) completed; {2} commit(s) created; {3} push(es) completed to {4}/{5}." -f `
        $script:autoPushCompleted,
        $script:autoPushTotal,
        $script:autoPushCommits,
        $script:autoPushPushes,
        (Format-PushBranch $script:autoPushRemote),
        (Format-PushBranch $script:autoPushRemoteBranch))
}

function Stop-Autopush {
    param([Parameter(Mandatory = $true)][string]$Message)

    [Console]::Error.WriteLine("git autopush: $Message")
    [Console]::Error.WriteLine("git autopush: stopped in repository `"$($script:autoPushRepoName)`".")
    Write-AutopushSummary
    exit 1
}

try {
    $initialContext = Get-GitRepositoryContext
    $initialPlan = Get-GitSuggestionPlan $initialContext
    Set-AutopushAnalysis $initialContext $initialPlan
}
catch {
    Fail $_.Exception.Message
}

if ($initialPlan.Entries.Count -eq 0) {
    Write-Output "Repository `"$($initialContext.RepoName)`" is up to date."
    Write-Output 'Nothing to commit or push.'
    exit 0
}

$script:autoPushTotal = @($initialPlan.Suggestions).Count
$script:autoPushBranch = $initialContext.Branch
$script:autoPushRepoName = $initialContext.RepoName
$initialRemoteUrl = ''
try {
    $initialTarget = Get-AutopushTarget $initialContext
    $script:autoPushRemote = $initialTarget.Name
    $script:autoPushRemoteBranch = $initialTarget.Branch
    $initialRemoteReady = Test-AutopushRemote $initialContext $initialTarget
    $initialRemoteUrl = $initialTarget.Url
}
catch { Fail $_.Exception.Message }
$initialBranch = $initialContext.Branch

$initialByKey = @{}
$pendingKeys = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($suggestion in @($initialPlan.Suggestions)) {
    $initialByKey[$suggestion.Key] = $suggestion
    [void]$pendingKeys.Add($suggestion.Key)
}

Write-Output "# Repository `"$($initialContext.RepoName)`" | branch: $($initialContext.Branch)"
Write-Output "# Run from: $($initialContext.RepoRoot)"
Write-Output "# Pending: $($initialPlan.Entries.Count) file(s) | added $($initialPlan.AddedCount), modified $($initialPlan.ModifiedCount), deleted $($initialPlan.DeletedCount), untracked $($initialPlan.UntrackedCount) | staged $($initialPlan.StagedCount) (staged overlaps)"
Write-Output ("# Remote checked: {0}/{1} {2}" -f $initialTarget.Name, $initialTarget.Branch, $(if ($initialRemoteReady) { 'is not ahead of local HEAD' } else { 'branch will be created by the first push' }))
Write-Output '# Re-checking changes and remote state before staging and pushing; stopping on any failure or stale suggestion.'
Write-Output '# Proposed commit messages:'
Write-Output 'Changed files:'
foreach ($suggestion in @($initialPlan.Suggestions)) {
    $label = if ($suggestion.IsRename) { "renamed: $($suggestion.OldPath) -> $($suggestion.Path)" } elseif ($suggestion.IsDeleted) { "deleted: $($suggestion.Path)" } elseif ($suggestion.IsUntracked -or $suggestion.X -eq 'A') { "added: $($suggestion.Path)" } else { "modified: $($suggestion.Path)" }
    Write-Output ("  {0}" -f $label)
    Write-Output ("    Summary: {0}" -f $suggestion.Summary)
    if (-not $combined) { Write-Output ("    Proposed commit: {0}" -f $suggestion.Message) }
}
if ($combined) {
    Write-Output ("  Combined summary: {0}" -f ((@($initialPlan.Suggestions | ForEach-Object { $_.Summary } | Select-Object -Unique) | Select-Object -First 3) -join '; '))
    Write-Output ("  Proposed commit: {0}" -f (Get-GitCombinedMessage $initialPlan.Suggestions))
}
Write-Output ''
if ((Read-Host 'Continue with the configured add, commit, and push workflow? [y/N]') -notmatch '^(?i:y|yes)$') {
    Write-Output 'Autopush cancelled; no files were staged, committed, or pushed.'
    exit 0
}

if ($combined) {
    try {
        $currentContext = Get-GitRepositoryContext
        if ($currentContext.Branch -cne $initialBranch) { throw 'branch changed after confirmation; stopping.' }
        $currentTarget = Get-AutopushTarget $currentContext
        if ($currentTarget.Name -cne $initialTarget.Name -or $currentTarget.Url -cne $initialRemoteUrl -or $currentTarget.Ref -cne $initialTarget.Ref) { throw 'push remote changed after confirmation; stopping.' }
        [void](Test-AutopushRemote $currentContext $currentTarget)
        $currentPlan = Get-GitSuggestionPlan $currentContext
        Set-AutopushAnalysis $currentContext $currentPlan
        if ($currentPlan.Suggestions.Count -ne $initialPlan.Suggestions.Count) { throw 'pending changes changed after confirmation; stopping.' }
        for ($i = 0; $i -lt $initialPlan.Suggestions.Count; $i++) {
            if ($currentPlan.Suggestions[$i].Key -cne $initialPlan.Suggestions[$i].Key -or $currentPlan.Suggestions[$i].Message -cne $initialPlan.Suggestions[$i].Message -or $currentPlan.Suggestions[$i].DiffHash -cne $initialPlan.Suggestions[$i].DiffHash) { throw 'pending changes or suggested messages changed after confirmation; stopping.' }
        }
        foreach ($suggestion in $currentPlan.Suggestions) {
            if ($suggestion.NeedsAdd) {
                $addResult = Invoke-GitAction $suggestion.AddArguments
                if ($addResult.ExitCode -ne 0) { throw ("git add failed for '$($suggestion.Path)'.`n" + (Format-GitFailure $addResult)) }
            }
        }
        $stagedContext = Get-GitRepositoryContext
        $stagedPlan = Get-GitSuggestionPlan $stagedContext
        Set-AutopushAnalysis $stagedContext $stagedPlan
        if ($stagedPlan.Suggestions.Count -ne $initialPlan.Suggestions.Count) { throw 'pending changes changed while staging; stopping before commit.' }
        for ($i = 0; $i -lt $initialPlan.Suggestions.Count; $i++) {
            if ($stagedPlan.Suggestions[$i].DiffHash -cne $initialPlan.Suggestions[$i].DiffHash) { throw 'file contents changed after confirmation; stopping before commit.' }
        }
        $currentPlan = $stagedPlan
        $commitPaths = @($currentPlan.Suggestions | ForEach-Object { $_.CommitPaths } | Select-Object -Unique)
        $message = Get-GitCombinedMessage $currentPlan.Suggestions
        $headBefore = (Invoke-GitDetect @('-C', $currentContext.RepoRoot, 'rev-parse', '--verify', 'HEAD')).Output -join ''
        $commit = Invoke-GitAction (@('--literal-pathspecs', '-C', $currentContext.RepoRoot, 'commit', '-m', $message, '--') + $commitPaths)
        if ($commit.ExitCode -ne 0) { throw ("git commit failed.`n" + (Format-GitFailure $commit)) }
        $headAfter = (Invoke-GitDetect @('-C', $currentContext.RepoRoot, 'rev-parse', '--verify', 'HEAD')).Output -join ''
        if ([string]::IsNullOrWhiteSpace($headAfter) -or $headAfter -ceq $headBefore) { throw 'the combined commit did not create a new commit.' }
        $script:autoPushCommits = 1
        [void](Test-AutopushRemote (Get-GitRepositoryContext) $initialTarget)
        $pushSpec = 'HEAD:' + $initialTarget.Ref
        $push = Invoke-GitAction @('-C', $currentContext.RepoRoot, 'push', $initialTarget.Name, $pushSpec)
        if ($push.ExitCode -ne 0) { throw ("git push $($initialTarget.Name) $pushSpec failed after the combined commit. No force-push was attempted.`n" + (Format-GitFailure $push)) }
        $script:autoPushCompleted = $script:autoPushTotal
        $script:autoPushPushes = 1
        $finalPlan = Get-GitSuggestionPlan (Get-GitRepositoryContext)
        if ($finalPlan.Entries.Count -gt 0) { throw 'new pending changes remain after the combined push.' }
        Write-Output ("Autopush complete: {0} file(s), 1 commit, 1 push to {1}/{2}." -f $script:autoPushCompleted, (Format-PushBranch $initialTarget.Name), (Format-PushBranch $initialTarget.Branch))
        exit 0
    }
    catch { Stop-Autopush $_.Exception.Message }
}

foreach ($planned in @($initialPlan.Suggestions)) {
    $number = $script:autoPushCompleted + 1
    Write-Output "[$number/$script:autoPushTotal] $($planned.Kind) '$($planned.Path)'"

    try {
        $currentContext = Get-GitRepositoryContext

        if ($currentContext.Branch -cne $initialBranch) {
            throw "branch changed from '$initialBranch' to '$($currentContext.Branch)' while autopush was running; stopping."
        }
        $currentTarget = Get-AutopushTarget $currentContext
        if ($currentTarget.Name -cne $initialTarget.Name -or $currentTarget.Url -cne $initialRemoteUrl -or $currentTarget.Ref -cne $initialTarget.Ref) { throw 'push remote changed while autopush was running; stopping.' }
        [void](Test-AutopushRemote $currentContext $currentTarget)

        $currentPlan = Get-GitSuggestionPlan $currentContext
        Set-AutopushAnalysis $currentContext $currentPlan
        $currentByKey = @{}
        $currentKeys = New-Object 'System.Collections.Generic.HashSet[string]'

        foreach ($suggestion in @($currentPlan.Suggestions)) {
            if (-not $currentKeys.Add($suggestion.Key)) {
                throw "duplicate pending change detected for '$($suggestion.Path)'; stopping."
            }
            $currentByKey[$suggestion.Key] = $suggestion
        }

        $setsMatch = ($pendingKeys.Count -eq $currentKeys.Count)
        if ($setsMatch) {
            foreach ($key in $pendingKeys) {
                if (-not $currentKeys.Contains($key)) {
                    $setsMatch = $false
                    break
                }
            }
        }

        if (-not $setsMatch) {
            throw "pending changes changed while autopush was running; stopping before '$($planned.Path)'."
        }

        foreach ($key in $pendingKeys) {
            $expected = $initialByKey[$key]
            $observed = $currentByKey[$key]

            if ($null -eq $observed) {
                throw "the suggestion for '$($expected.Path)' disappeared while autopush was running; stopping."
            }

            $sameCommitPaths = (($observed.CommitPaths -join [string][char]0) -ceq ($expected.CommitPaths -join [string][char]0))
            if ($observed.NeedsAdd -ne $expected.NeedsAdd -or $observed.Message -cne $expected.Message -or $observed.DiffHash -cne $expected.DiffHash -or -not $sameCommitPaths) {
                throw "the suggestion for '$($expected.Path)' changed while autopush was running; refusing to use a stale suggestion."
            }
        }

        $current = $currentByKey[$planned.Key]
        if ($null -eq $current) {
            throw "the suggestion for '$($planned.Path)' is no longer available; stopping."
        }
    }
    catch {
        Stop-Autopush $_.Exception.Message
    }

    if ($current.NeedsAdd) {
        Write-Output "  add     $($current.DisplayAddCommand)"
        $addResult = Invoke-GitAction $current.AddArguments
        if ($addResult.ExitCode -ne 0) {
            Stop-Autopush ("git add failed for '$($current.Path)'." + "`n" + (Format-GitFailure $addResult))
        }
    }
    else {
        Write-Output '  add     skipped (already staged)'
    }

    $headBeforeResult = Invoke-GitDetect @('-C', $currentContext.RepoRoot, 'rev-parse', '--verify', 'HEAD')
    $headBefore = ''
    if ($headBeforeResult.ExitCode -eq 0) {
        $headBefore = ($headBeforeResult.Output -join '').Trim()
    }

    Write-Output "  commit  $($current.DisplayCommitCommand)"
    $commitResult = Invoke-GitAction $current.CommitArguments
    if ($commitResult.ExitCode -ne 0) {
        Stop-Autopush ("git commit failed for '$($current.Path)'." + "`n" + (Format-GitFailure $commitResult))
    }

    $headAfterResult = Invoke-GitDetect @('-C', $currentContext.RepoRoot, 'rev-parse', '--verify', 'HEAD')
    $headAfter = ''
    if ($headAfterResult.ExitCode -eq 0) {
        $headAfter = ($headAfterResult.Output -join '').Trim()
    }

    if ([string]::IsNullOrWhiteSpace($headAfter) -or $headAfter -ceq $headBefore) {
        Stop-Autopush "the commit for '$($current.Path)' did not create a new commit; stopping."
    }

    $script:autoPushCommits++
    $shortHead = $headAfter
    if ($shortHead.Length -gt 7) {
        $shortHead = $shortHead.Substring(0, 7)
    }
    Write-Output "           OK $shortHead"

    try { [void](Test-AutopushRemote (Get-GitRepositoryContext) $initialTarget) }
    catch { Stop-Autopush $_.Exception.Message }
    $pushSpec = 'HEAD:' + $initialTarget.Ref
    Write-Output ('  push    git push ' + (Format-PushBranch $initialTarget.Name) + ' HEAD:' + $initialTarget.Ref)
    $pushResult = Invoke-GitAction @('-C', $currentContext.RepoRoot, 'push', $initialTarget.Name, $pushSpec)
    if ($pushResult.ExitCode -ne 0) {
        Stop-Autopush ("git push $($initialTarget.Name) $pushSpec failed after committing '$($current.Path)'. No force-push was attempted.`n" + (Format-GitFailure $pushResult))
    }

    $script:autoPushPushes++
    [void]$pendingKeys.Remove($planned.Key)
    $script:autoPushCompleted++
    Write-Output '           OK'
    Write-Output ''
}

try {
    $finalContext = Get-GitRepositoryContext
    $finalPlan = Get-GitSuggestionPlan $finalContext
}
catch {
    Stop-Autopush "could not verify the final repository state: $($_.Exception.Message)"
}

if ($finalPlan.Entries.Count -gt 0) {
    Stop-Autopush "new pending changes appeared after autopush started and were not processed: $($finalPlan.Entries.Count) file(s)."
}

Write-Output ("Autopush complete: {0} file(s), {1} commit(s), {2} push(es) to {3}/{4}." -f `
    $script:autoPushCompleted,
    $script:autoPushCommits,
    $script:autoPushPushes,
    (Format-PushBranch $initialTarget.Name),
    (Format-PushBranch $initialTarget.Branch))
exit 0
