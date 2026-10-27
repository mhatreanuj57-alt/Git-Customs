$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

$script:CommandPrefix = 'git action-fix'
$script:ExitCode = 0

function Show-ActionFixUsage {
    Write-Output 'Usage: git action-fix [options]'
    Write-Output ''
    Write-Output 'Diagnose a failed GitHub Actions run, propose a targeted fix, require'
    Write-Output 'approval, then validate, push, and verify a recovery run.'
    Write-Output ''
    Write-Output 'With no options, selects the latest failed run on the current branch.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --run <id>                  Diagnose a specific workflow run'
    Write-Output '  --workflow <selector>       Filter by workflow name, path, filename, or id'
    Write-Output '  --branch <name>             Filter by branch (default: current branch)'
    Write-Output '  --all-branches              Include runs from every branch'
    Write-Output '  --dry-run                   Show diagnosis and proposed changes only'
    Write-Output '  --interval <seconds>        Poll interval (default: 10)'
    Write-Output '  --timeout <seconds>         CI watch timeout (default: 600)'
    Write-Output '  --discovery-timeout <sec>   New run/retry discovery timeout (default: 120)'
    Write-Output '  -h, --help                  Show this help'
    Write-Output ''
    Write-Output 'Safety:'
    Write-Output '  Automated edits require an interactive approval, a clean worktree,'
    Write-Output '  the exact failed commit, and a synchronized upstream branch. A second'
    Write-Output '  approval is required before committing and pushing. Secret files are'
    Write-Output '  never edited, and failures without a proven fix are never retried.'
    Write-Output ''
    Write-Output 'Exit codes: 0 for a verified recovery or completed dry run, 1 otherwise.'
}

function Write-ActionFixRunHeader {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run,
        [object[]]$FailedJobs
    )

    Write-Output "Repository:  $($Context.FullName)"
    Write-Output "Run:         $($Run.databaseId)"
    Write-Output "Workflow:    $($Run.workflowName)"
    Write-Output "Branch:      $($Run.headBranch)"
    Write-Output "Status:      $(Format-ActionWorkflowStatusLabel $Run)"
    Write-Output "Commit:      $($Run.headSha)"
    if (-not [string]::IsNullOrWhiteSpace([string]$Run.url)) {
        Write-Output "URL:         $($Run.url)"
    }
    $jobCount = @($FailedJobs).Count
    if ($jobCount -gt 0) {
        $jobNames = @($FailedJobs | ForEach-Object { "$($_.name) ($($_.databaseId))" }) -join ', '
        Write-Output "Failed jobs: $jobCount [$jobNames]"
    }
    else {
        Write-Output 'Failed jobs: 0'
    }
}

function Write-ActionFixDiagnosis {
    param([Parameter(Mandatory = $true)]$Diagnosis)

    Write-Output ''
    Write-Output 'Likely causes:'
    $findings = @($Diagnosis.Findings)
    for ($i = 0; $i -lt $findings.Count; $i++) {
        $finding = $findings[$i]
        Write-Output "$($i + 1). $($finding.Title) [$($finding.Confidence) confidence]"
        Write-Output "   $($finding.Explanation)"
        if (@($finding.Evidence).Count -gt 0) {
            Write-Output '   Evidence:'
            foreach ($line in @($finding.Evidence)) {
                Write-Output "     - $line"
            }
        }
        if ($null -ne $finding.Proposal) {
            Write-Output "   Affected file: $($finding.File)"
            Write-Output '   Proposed change:'
            foreach ($line in @($finding.Proposal.DiffLines)) {
                Write-Output "     $line"
            }
        }
        elseif ($finding.Action -ceq 'Retry') {
            Write-Output '   Proposed action: retry failed jobs after approval, then verify the run.'
        }
        else {
            Write-Output '   Proposed action: none; manual review is required.'
        }
    }

    $selectedNumber = 0
    for ($i = 0; $i -lt $findings.Count; $i++) {
        if ([object]::ReferenceEquals($findings[$i], $Diagnosis.Selected)) {
            $selectedNumber = $i + 1
            break
        }
    }
    if ($selectedNumber -eq 0) {
        $selectedNumber = 1
    }

    Write-Output ''
    Write-Output "Selected remediation: $selectedNumber. $($Diagnosis.Selected.Title)"
}

function Read-ActionFixConfirmation {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    Write-Host $Prompt
    $answer = [Console]::In.ReadLine()


    if ($null -eq $answer) {
        throw 'confirmation is required; run the command interactively and answer y to continue.'
    }
    if ($answer.Trim() -notmatch '^(?i:y|yes)$') {
        return $false
    }
    return $true
}

function Get-ActionFixStatusPaths {
    param([Parameter(Mandatory = $true)]$Context)

    $status = Invoke-ActionFixGit -Context $Context -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($status.Output)) {
        $text = [string]$line
        if ($text.Length -le 3) {
            continue
        }
        $path = $text.Substring(3).Trim()
        if ($path.StartsWith('"') -and $path.EndsWith('"') -and $path.Length -ge 2) {
            $path = $path.Substring(1, $path.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $paths.Add($path.Replace('\', '/'))
        }
    }
    return [object[]]$paths.ToArray()
}

function Invoke-ActionFixVerifyRecovery {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$RecoveryRun,
        [int]$Interval,
        [int]$Timeout
    )

    Write-Output "Recovery run: $($RecoveryRun.databaseId) | $($RecoveryRun.url)"
    $watch = Invoke-ActionFixWorkflowCommand -Context $Context -Arguments @(
        'watch',
        '--run', [string]$RecoveryRun.databaseId,
        '--interval', [string]$Interval,
        '--timeout', [string]$Timeout
    )
    if (-not [string]::IsNullOrWhiteSpace($watch.Text)) {
        Write-Output $watch.Text
    }

    if ($watch.ExitCode -eq 0) {
        Write-Output ''
        Write-Output "Recovery succeeded: workflow run $($RecoveryRun.databaseId) completed successfully."
        $script:ExitCode = 0
        return
    }

    Write-Output ''
    Write-Output "Recovery did not succeed: workflow run $($RecoveryRun.databaseId) did not finish successfully."
    Write-Output "Inspect it with: $($script:CommandPrefix) --run $($RecoveryRun.databaseId)"
    $script:ExitCode = 1
    return
}

function Invoke-ActionFixEditPlan {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Finding,
        [int]$Interval,
        [int]$Timeout,
        [int]$DiscoveryTimeout
    )

    $ready = Assert-ActionFixEditReady -Context $Context -Run $Run
    $proposal = $Finding.Proposal
    if ($null -eq $proposal) {
        throw 'the selected edit plan has no proposed change.'
    }

    if (-not (Read-ActionFixConfirmation "Apply the proposed change to '$($proposal.File)'? [y/N]")) {
        throw 'fix cancelled.'
    }

    $rollback = $null
    $commitCreated = $false
    try {
        $rollback = Set-ActionFixProposal -Context $Context -Proposal $proposal
        Write-Output "Applied: $($proposal.File)"

        $validation = Invoke-ActionFixWorkflowCommand -Context $Context -Arguments @('validate')
        if ($validation.ExitCode -ne 0) {
            throw "workflow validation failed after applying the fix.`n$($validation.Text)"
        }
        Write-Output 'Validation: PASS'

        $changedPaths = @(Get-ActionFixStatusPaths $Context)
        if ($changedPaths.Count -ne 1 -or $changedPaths[0] -ine $proposal.File) {
            $found = if ($changedPaths.Count -gt 0) { $changedPaths -join ', ' } else { 'none' }
            throw "unexpected files changed while preparing the fix (expected '$($proposal.File)', found: $found)."
        }

        $headResult = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', 'HEAD')
        $currentHead = (($headResult.Output -join '').Trim())
        if ($currentHead -cne $ready.Head) {
            throw 'local HEAD changed while the fix was being prepared.'
        }
        $remoteResult = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', '--quiet', $ready.RemoteRef) -AllowFailure
        $currentRemote = (($remoteResult.Output -join '').Trim())
        if ($remoteResult.ExitCode -ne 0 -or $currentRemote -cne $ready.Head) {
            throw "origin/$($Context.Branch) changed while the fix was being prepared."
        }

        if (-not (Read-ActionFixConfirmation "Commit and push this change to recover run $($Run.databaseId)? [y/N]")) {
            Write-Output 'Recovery cancelled. The approved edit remains uncommitted; no commit or push was made.'
            $script:ExitCode = 1
            return
        }

        $null = Invoke-ActionFixGit -Context $Context -Arguments @('add', '--', $proposal.File)
        $staged = Invoke-ActionFixGit -Context $Context -Arguments @('diff', '--cached', '--name-only')
        $stagedPaths = @($staged.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Replace('\', '/') })
        if ($stagedPaths.Count -ne 1 -or $stagedPaths[0] -ine $proposal.File) {
            throw "the staged change set is not limited to '$($proposal.File)'."
        }

        $commitBody = "Recover GitHub Actions run $($Run.databaseId) with git action-fix."
        $commitResult = Invoke-ActionFixGit -Context $Context -Arguments @(
            'commit', '-m', $proposal.CommitTitle, '-m', $commitBody, '--', $proposal.File
        ) -AllowFailure
        if ($commitResult.ExitCode -ne 0) {
            $headAfterCommit = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', 'HEAD')
            $headValue = (($headAfterCommit.Output -join '').Trim())
            if ($headValue -ceq $ready.Head) {
                throw "git commit failed.`n$(Format-ActionWorkflowFailure $commitResult)"
            }
            throw "git commit reported an error after changing HEAD; no push was attempted.`n$(Format-ActionWorkflowFailure $commitResult)"
        }
        $commitCreated = $true

        $commitPathsResult = Invoke-ActionFixGit -Context $Context -Arguments @('show', '--pretty=format:', '--name-only', 'HEAD')
        $committedPaths = @($commitPathsResult.Output |
            ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Replace('\', '/') })
        if ($committedPaths.Count -ne 1 -or $committedPaths[0] -ine $proposal.File) {
            throw 'the new commit contains unexpected paths; no push was attempted.'
        }

        $commitSha = (($commitResult.Output | Where-Object { [string]$_ -match '^\[[^\]]+\s+(?<sha>[0-9a-f]+)\]' } |
            ForEach-Object { [regex]::Match([string]$_, '^\[[^\]]+\s+(?<sha>[0-9a-f]+)\]').Groups['sha'].Value } |
            Select-Object -First 1))
        if ([string]::IsNullOrWhiteSpace($commitSha)) {
            $headResult = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--short', 'HEAD')
            $commitSha = (($headResult.Output -join '').Trim())
        }
        Write-Output "Commit: $commitSha | $($proposal.CommitTitle)"

        $pushResult = Invoke-ActionFixGit -Context $Context -Arguments @('push', 'origin', $Context.Branch) -AllowFailure
        if ($pushResult.ExitCode -ne 0) {
            throw "the fix was committed locally, but git push failed. No force-push was attempted.`n$(Format-ActionWorkflowFailure $pushResult)"
        }
        Write-Output "Pushed: origin/$($Context.Branch)"

        $newHeadResult = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', 'HEAD')
        $newHead = (($newHeadResult.Output -join '').Trim())
        if ($newHead -cne $ready.Head) {
            Write-Output 'Waiting for the new GitHub Actions run...'
            $recovery = Wait-ActionFixNewRun -Context $Context -OriginalRun $Run -HeadSha $newHead `
                -Timeout $DiscoveryTimeout -Interval $Interval
            Invoke-ActionFixVerifyRecovery -Context $Context -RecoveryRun $recovery -Interval $Interval -Timeout $Timeout
            return
        }

        throw 'the local commit could not be verified after push.'
    }
    catch {
        $message = $_.Exception.Message
        if ($null -ne $rollback -and -not $commitCreated) {
            $headNow = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', 'HEAD') -AllowFailure
            $headValue = (($headNow.Output -join '').Trim())
            if ($headNow.ExitCode -eq 0 -and $headValue -ceq $ready.Head) {
                try {
                    Undo-ActionFixProposal -Context $Context -Rollback $rollback
                    $message += "`nThe edit was rolled back."
                }
                catch {
                    $message += "`nThe edit could not be rolled back: $($_.Exception.Message)"
                }
            }
            else {
                $message += "`nA local commit exists; it was not pushed."
            }
        }
        throw $message
    }
}

function Invoke-ActionFixRetryPlan {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run,
        [int]$Interval,
        [int]$Timeout,
        [int]$DiscoveryTimeout
    )

    if (-not (Read-ActionFixConfirmation "Retry failed jobs for run $($Run.databaseId) after this diagnosis? [y/N]")) {
        throw 'retry cancelled.'
    }

    $retry = Invoke-ActionFixWorkflowCommand -Context $Context -Arguments @(
        'retry', '--run', [string]$Run.databaseId, '--yes'
    )
    if (-not [string]::IsNullOrWhiteSpace($retry.Text)) {
        Write-Output $retry.Text
    }
    if ($retry.ExitCode -ne 0) {
        throw 'the existing workflow engine refused the retry request.'
    }

    $current = Wait-ActionFixRerunStart -Context $Context -OriginalRun $Run -Timeout $DiscoveryTimeout -Interval $Interval
    Invoke-ActionFixVerifyRecovery -Context $Context -RecoveryRun $current -Interval $Interval -Timeout $Timeout
}

function Invoke-ActionFix {
    param([string[]]$Arguments)

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{
            '--run' = 'run'
            '--workflow' = 'workflow'
            '--branch' = 'branch'
            '--interval' = 'interval'
            '--timeout' = 'timeout'
            '--discovery-timeout' = 'discoveryTimeout'
        } `
        -SwitchOptions @{
            '--all-branches' = 'allBranches'
            '--dry-run' = 'dryRun'
        }

    $interval = 10
    $timeout = 600
    $discoveryTimeout = 120
    if (-not [string]::IsNullOrWhiteSpace([string]$options.interval)) {
        $interval = ConvertTo-ActionWorkflowPositiveInteger -Value ([string]$options.interval) -Name '--interval' -Minimum 1 -Maximum 300
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$options.timeout)) {
        $timeout = ConvertTo-ActionWorkflowPositiveInteger -Value ([string]$options.timeout) -Name '--timeout' -Minimum 1 -Maximum 86400
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$options.discoveryTimeout)) {
        $discoveryTimeout = ConvertTo-ActionWorkflowPositiveInteger -Value ([string]$options.discoveryTimeout) -Name '--discovery-timeout' -Minimum 1 -Maximum 3600
    }

    $context = Get-ActionWorkflowContext
    $branch = ConvertTo-ActionWorkflowBranchFilter -Branch ([string]$options.branch) -AllBranches:([bool]$options.allBranches)
    if ([string]::IsNullOrWhiteSpace([string]$options.run) -and -not $options.allBranches -and [string]::IsNullOrWhiteSpace($branch)) {
        $branch = $context.Branch
    }

    $workflow = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$options.workflow)) {
        $workflow = Resolve-ActionWorkflow $context ([string]$options.workflow)
    }

    $workflowSelector = ''
    if ($null -ne $workflow) {
        $workflowSelector = [string]$workflow.path
    }

    $run = Resolve-ActionWorkflowRun -Context $context -RunId ([string]$options.run) `
        -WorkflowSelector $workflowSelector -Branch $branch -AllBranches:([bool]$options.allBranches)

    if ([string]$run.status -ne 'completed') {
        throw "workflow run '$($run.databaseId)' is $(Format-ActionWorkflowStatusLabel $run); wait for it to finish before diagnosing it."
    }

    $failedConclusions = @('failure', 'timed_out', 'action_required', 'startup_failure', 'cancelled')
    if ([string]$run.conclusion -notin $failedConclusions) {
        throw "workflow run '$($run.databaseId)' concluded '$($run.conclusion)'; there is no failed run to repair."
    }

    $failedJobs = @(Get-ActionFixFailedJobs -Context $context -Run $run)
    Write-ActionFixRunHeader -Context $context -Run $run -FailedJobs $failedJobs

    $logs = Get-ActionFixLogs -Context $context -Run $run
    Write-Output "Logs:        $($logs.Mode) ($($logs.Lines) lines analyzed)"
    foreach ($warning in @($logs.Warnings)) {
        Write-Output "WARNING: $(Protect-ActionFixSensitiveText ([string]$warning))"
    }

    $localWorkflow = Get-ActionFixLocalWorkflowForRun -Context $context -Run $run
    $diagnosis = Get-ActionFixDiagnosis -Context $context -Run $run -Workflow $localWorkflow -LogText $logs.Text
    Write-ActionFixDiagnosis $diagnosis

    if ($options.dryRun) {
        Write-Output ''
        Write-Output 'Dry run: no files were changed and no workflow run was retried.'
        $script:ExitCode = 0
        return
    }

    $selected = $diagnosis.Selected
    if ($selected.Action -ceq 'Edit') {
        Write-Output ''
        Write-Output 'Safety: the edit is applied only when the current branch, exact failed commit, clean worktree, and origin tracking branch all match.'
        Invoke-ActionFixEditPlan -Context $context -Run $run -Finding $selected `
            -Interval $interval -Timeout $timeout -DiscoveryTimeout $discoveryTimeout
        return
    }

    if ($selected.Action -ceq 'Retry') {
        Invoke-ActionFixRetryPlan -Context $context -Run $run `
            -Interval $interval -Timeout $timeout -DiscoveryTimeout $discoveryTimeout
        return
    }

    Write-Output ''
    Write-Output 'No automatic change or retry will be attempted for this failure.'
    Write-Output "Review the logs with: $($script:CommandPrefix) --run $($run.databaseId) --dry-run"
    $script:ExitCode = 1
    return
}

$workflowCorePath = Join-Path $PSScriptRoot 'git-action-workflow-core.ps1'
$fixCorePath = Join-Path $PSScriptRoot 'git-action-fix-core.ps1'
foreach ($corePath in @($workflowCorePath, $fixCorePath)) {
    if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
        [Console]::Error.WriteLine("$($script:CommandPrefix): missing required file: $corePath")
        exit 1
    }
}

try {
    . $workflowCorePath
    . $fixCorePath
}
catch {
    [Console]::Error.WriteLine("$($script:CommandPrefix): could not load the shared engine: $($_.Exception.Message)")
    exit 1
}

try {
    $script:ExitCode = 0
    $helpRequested = $false
    foreach ($argument in @($args)) {
        if ([string]$argument -in @('-h', '--help')) {
            $helpRequested = $true
            break
        }
    }

    if ($helpRequested) {
        Show-ActionFixUsage
        exit 0
    }

    Invoke-ActionFix -Arguments ([string[]]$args)
    exit [int]$script:ExitCode
}
catch {
    [Console]::Error.WriteLine("$($script:CommandPrefix): $(Protect-ActionFixSensitiveText $_.Exception.Message)")
    exit 1
}
