$ErrorActionPreference = 'Continue'

if ($args -contains '--help' -or $args -contains '-h') {
    Write-Output 'Usage: git autopush [--combined]'
    Write-Output ''
    Write-Output 'Re-detects the pending changes reported by git suggest, then stages,'
    Write-Output 'commits, and pushes each file individually. --combined creates one commit.'
    Write-Output 'It stops if anything fails or if pending changes change during the run.'
    Write-Output 'Requires a Git working tree with an origin remote and a checked-out branch.'
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

function Write-AutopushSummary {
    Write-Output ''
    Write-Output ("Autopush summary: {0} of {1} file(s) completed; {2} commit(s) created; {3} push(es) completed to origin/{4}." -f `
        $script:autoPushCompleted,
        $script:autoPushTotal,
        $script:autoPushCommits,
        $script:autoPushPushes,
        (Format-PushBranch $script:autoPushBranch))
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
$initialOriginUrl = $initialContext.OriginUrl
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
Write-Output '# Re-checking the pending changes before every file; stopping on any failure or stale suggestion.'
Write-Output '# Proposed commit messages:'
if ($combined) { Write-Output ("  combined: {0}" -f (Get-GitCombinedMessage $initialPlan.Suggestions)) }
else { foreach ($suggestion in @($initialPlan.Suggestions)) { Write-Output ("  {0}: {1}" -f $suggestion.Path, $suggestion.Message) } }
Write-Output ''
if ((Read-Host 'Continue with the configured add, commit, and push workflow? [y/N]') -notmatch '^(?i:y|yes)$') {
    Write-Output 'Autopush cancelled; no files were staged, committed, or pushed.'
    exit 0
}

if ($combined) {
    try {
        $currentContext = Get-GitRepositoryContext
        if ($currentContext.Branch -cne $initialBranch -or $currentContext.OriginUrl -cne $initialOriginUrl) { throw 'branch or origin changed after confirmation; stopping.' }
        $currentPlan = Get-GitSuggestionPlan $currentContext
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
        $stagedPlan = Get-GitSuggestionPlan (Get-GitRepositoryContext)
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
        $push = Invoke-GitAction @('-C', $currentContext.RepoRoot, 'push', 'origin', $initialBranch)
        if ($push.ExitCode -ne 0) { throw ("git push origin $initialBranch failed after the combined commit.`n" + (Format-GitFailure $push)) }
        $script:autoPushCompleted = $script:autoPushTotal
        $script:autoPushPushes = 1
        $finalPlan = Get-GitSuggestionPlan (Get-GitRepositoryContext)
        if ($finalPlan.Entries.Count -gt 0) { throw 'new pending changes remain after the combined push.' }
        Write-Output ("Autopush complete: {0} file(s), 1 commit, 1 push to origin/{1}." -f $script:autoPushCompleted, (Format-PushBranch $initialBranch))
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
        if ($currentContext.OriginUrl -cne $initialOriginUrl) {
            throw "the origin remote changed while autopush was running; stopping."
        }

        $currentPlan = Get-GitSuggestionPlan $currentContext
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

    Write-Output ('  push    git push origin ' + (Format-PushBranch $initialBranch))
    $pushResult = Invoke-GitAction @('-C', $currentContext.RepoRoot, 'push', 'origin', $initialBranch)
    if ($pushResult.ExitCode -ne 0) {
        Stop-Autopush ("git push origin $initialBranch failed after committing '$($current.Path)'." + "`n" + (Format-GitFailure $pushResult))
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

Write-Output ("Autopush complete: {0} file(s), {1} commit(s), {2} push(es) to origin/{3}." -f `
    $script:autoPushCompleted,
    $script:autoPushCommits,
    $script:autoPushPushes,
    (Format-PushBranch $initialBranch))
exit 0
