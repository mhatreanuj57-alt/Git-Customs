$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

$script:CommandPrefix = 'git action-workflow'

function Show-ActionWorkflowUsage {
    Write-Output 'Usage: git action-workflow <command> [options]'
    Write-Output ''
    Write-Output 'Manage GitHub Actions workflows for the current repository.'
    Write-Output ''
    Write-Output 'Commands:'
    Write-Output '  init      Create a starter workflow without overwriting existing files'
    Write-Output '  validate  Validate local workflows and GitHub access'
    Write-Output '  status    Show recent workflow runs'
    Write-Output '  watch     Watch a verified workflow run until it finishes'
    Write-Output '  logs      Show logs for a verified workflow run'
    Write-Output '  retry     Re-run a completed workflow run after confirmation'
    Write-Output ''
    Write-Output "Run '$($script:CommandPrefix) <command> -h' for command options."
}

function Show-ActionWorkflowInitHelp {
    Write-Output 'Usage: git action-workflow init [--name <workflow-name>] [--file <filename>] [--dry-run]'
    Write-Output ''
    Write-Output 'Creates .github/workflows/action-workflow.yml with a minimal smoke-test'
    Write-Output 'workflow. Existing files are never overwritten. The file is not staged,'
    Write-Output 'committed, or pushed.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --name <name>  Workflow display name (default: Action Workflow)'
    Write-Output '  --file <name>  Workflow filename or basename (default: action-workflow.yml)'
    Write-Output '  --dry-run      Print the target and content without writing anything'
}

function Show-ActionWorkflowValidateHelp {
    Write-Output 'Usage: git action-workflow validate [--workflow <selector>] [--require-remote]'
    Write-Output ''
    Write-Output 'Checks local workflow structure, gh authentication, repository access, and'
    Write-Output 'remote workflow registration. Unregistered workflows are warnings by default.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --workflow <selector>  Validate one workflow by name, path, filename, or id'
    Write-Output '  --require-remote       Fail when a selected local workflow is not registered'
}

function Show-ActionWorkflowStatusHelp {
    Write-Output 'Usage: git action-workflow status [--workflow <selector>] [--branch <name>] [--all-branches] [--limit <count>]'
    Write-Output ''
    Write-Output 'Shows recent workflow runs. By default, shows runs for the current branch.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --workflow <selector>  Filter by workflow name, path, filename, or id'
    Write-Output '  --branch <name>        Filter by branch (default: current branch)'
    Write-Output '  --all-branches         Include runs from every branch'
    Write-Output '  --limit <count>        Number of runs to show (1-100, default: 10)'
}

function Show-ActionWorkflowWatchHelp {
    Write-Output 'Usage: git action-workflow watch [--run <id>] [--workflow <selector>] [--branch <name>] [--all-branches] [--interval <seconds>] [--timeout <seconds>]'
    Write-Output ''
    Write-Output 'Watches a verified workflow run until it finishes. Without --run, watches'
    Write-Output 'the latest matching run. The command exits with the run result.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --run <id>             Watch a specific run id'
    Write-Output '  --workflow <selector>  Filter by workflow name, path, filename, or id'
    Write-Output '  --branch <name>        Filter by branch; not defaulted when --run is used'
    Write-Output '  --all-branches         Include runs from every branch'
    Write-Output '  --interval <seconds>   Poll interval in seconds (default: 10)'
    Write-Output '  --timeout <seconds>    Maximum wait in seconds (default: 600)'
    Write-Output ''
    Write-Output 'Exit codes: 0 for success/neutral/skipped, 1 for any other conclusion or timeout.'
}

function Show-ActionWorkflowLogsHelp {
    Write-Output 'Usage: git action-workflow logs [--run <id>] [--workflow <selector>] [--branch <name>] [--all-branches] [--failed] [--job <id>]'
    Write-Output ''
    Write-Output 'Prints logs for a verified workflow run. Without --run, uses the latest'
    Write-Output 'matching run. Logs are retrieved only after run and job verification.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --run <id>             Show logs for a specific run id'
    Write-Output '  --workflow <selector>  Filter by workflow name, path, filename, or id'
    Write-Output '  --branch <name>        Filter by branch; not defaulted when --run is used'
    Write-Output '  --all-branches         Include runs from every branch'
    Write-Output '  --failed               Show only failed steps'
    Write-Output '  --job <id>             Show logs for one verified job in the run'
}

function Show-ActionWorkflowRetryHelp {
    Write-Output 'Usage: git action-workflow retry [--run <id>] [--workflow <selector>] [--branch <name>] [--all-branches] [--all] [--yes]'
    Write-Output ''
    Write-Output 'Re-runs a completed, unsuccessful workflow run. By default, only failed'
    Write-Output 'jobs are re-run. The run status and jobs are verified before the request.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --run <id>             Retry a specific run id'
    Write-Output '  --workflow <selector>  Filter by workflow name, path, filename, or id'
    Write-Output '  --branch <name>        Filter by branch; not defaulted when --run is used'
    Write-Output '  --all-branches         Include runs from every branch'
    Write-Output '  --all                  Re-run all jobs instead of only failed jobs'
    Write-Output '  --yes                  Skip the interactive confirmation prompt'
}

function Get-ActionWorkflowFailedJobs {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run
    )

    $failedConclusions = @('failure', 'timed_out', 'action_required', 'startup_failure', 'cancelled')
    $jobs = @(Get-ActionWorkflowJobs $Context $Run)
    return [object[]]@($jobs | Where-Object { [string]$_.conclusion -in $failedConclusions })
}

function Format-ActionWorkflowTimestamp {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return '-'
    }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    }
    return $Value
}

function Get-ActionWorkflowInitFileName {
    param([string]$Value)

    $candidate = 'action-workflow.yml'
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $candidate = $Value.Trim()
    }

    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($candidate))) {
        $candidate += '.yml'
    }
    if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]*\.(?:yml|yaml)$') {
        throw "workflow filename '$candidate' is not valid; use a basename ending in .yml or .yaml."
    }
    return $candidate
}

function Get-ActionWorkflowInitName {
    param([string]$Value)

    $candidate = 'Action Workflow'
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $candidate = $Value.Trim()
    }
    if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$') {
        throw 'workflow name must be 1-80 characters using letters, digits, spaces, dots, underscores, or dashes.'
    }
    return $candidate
}

function Invoke-ActionWorkflowInit {
    param([string[]]$Arguments)

    if ($Arguments -contains '-h' -or $Arguments -contains '--help') {
        Show-ActionWorkflowInitHelp
        return
    }

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{ '--name' = 'name'; '--file' = 'file' } `
        -SwitchOptions @{ '--dry-run' = 'dryRun' }

    $context = Get-ActionWorkflowRepositoryContext
    $workflowName = Get-ActionWorkflowInitName ([string]$options.name)
    $fileName = Get-ActionWorkflowInitFileName ([string]$options.file)
    $relativePath = ".github/workflows/$fileName"
    $workflowDirectory = Join-Path (Join-Path $context.RepoRoot '.github') 'workflows'
    $targetPath = Join-Path $workflowDirectory $fileName

    if (Test-Path -LiteralPath $targetPath) {
        throw "refusing to overwrite existing workflow file: $relativePath"
    }

    $content = New-ActionWorkflowTemplate $workflowName

    if ($options.dryRun) {
        Write-Output "Dry run: would create $relativePath"
        Write-Output "Repository: $($context.FullName) | branch: $($context.Branch)"
        Write-Output ''
        Write-Output $content.TrimEnd()
        return
    }

    try {
        New-Item -ItemType Directory -Path $workflowDirectory -Force -ErrorAction Stop | Out-Null
    }
    catch {
        throw "could not create the workflow directory: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $targetPath) {
        throw "refusing to overwrite existing workflow file: $relativePath"
    }

    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($content)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $targetPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch [System.IO.IOException] {
        throw "refusing to overwrite existing workflow file: $relativePath"
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    Write-Output "Repository: $($context.FullName) | branch: $($context.Branch)"
    Write-Output "Created: $relativePath"
    Write-Output "Workflow: $workflowName"
    Write-Output 'No files were staged, committed, or pushed.'
    Write-Output ''
    Write-Output 'Next:'
    Write-Output ('  git add -- ' + (ConvertTo-ActionWorkflowPowerShellLiteral $relativePath))
    Write-Output ('  git commit -m ' + (ConvertTo-ActionWorkflowPowerShellLiteral "Add $workflowName workflow") + ' -- ' + (ConvertTo-ActionWorkflowPowerShellLiteral $relativePath))
    Write-Output ('  git push origin ' + (ConvertTo-ActionWorkflowPowerShellLiteral $context.Branch))
    Write-Output "  $($script:CommandPrefix) validate"
}

function Find-ActionWorkflowLocalMatches {
    param(
        [object[]]$Workflows,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $value = $Selector.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'the workflow selector is empty.'
    }
    if ($value -match '^[0-9]+$') {
        return @()
    }

    $normalized = $value.Replace('\', '/').TrimStart('.', '/')
    $byPath = @($Workflows | Where-Object {
        ([string]$_.Path).Replace('\', '/').TrimStart('.', '/') -ieq $normalized
    })
    if ($byPath.Count -gt 0) {
        return [object[]]$byPath
    }

    $byFile = @($Workflows | Where-Object { [string]$_.FileName -ieq $value })
    if ($byFile.Count -gt 0) {
        return [object[]]$byFile
    }

    return [object[]]@($Workflows | Where-Object { [string]$_.Name -ieq $value })
}

function Invoke-ActionWorkflowValidate {
    param([string[]]$Arguments)

    if ($Arguments -contains '-h' -or $Arguments -contains '--help') {
        Show-ActionWorkflowValidateHelp
        return
    }

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{ '--workflow' = 'workflow' } `
        -SwitchOptions @{ '--require-remote' = 'requireRemote' }

    $context = Get-ActionWorkflowContext
    $localWorkflows = @(Get-ActionWorkflowLocalWorkflowFiles $context)
    if ($localWorkflows.Count -eq 0) {
        throw 'no workflow files were found in .github/workflows; run git action-workflow init first.'
    }

    $remoteWorkflows = @(Get-ActionWorkflowList $context)
    $selector = [string]$options.workflow
    $selectedLocal = @($localWorkflows)
    $selectedRemote = @($remoteWorkflows)

    if (-not [string]::IsNullOrWhiteSpace($selector)) {
        $selectedLocal = @(Find-ActionWorkflowLocalMatches $localWorkflows $selector)
        if ($selectedLocal.Count -gt 1) {
            $paths = @($selectedLocal | ForEach-Object { $_.Path }) -join ', '
            throw "workflow selector '$selector' is ambiguous locally. Matches: $paths"
        }

        $selectedRemote = @(Find-ActionWorkflowMatchesFromList $remoteWorkflows $selector)
        if ($selectedRemote.Count -gt 1) {
            $paths = @($selectedRemote | ForEach-Object { "$($_.name) [$($_.path)]" }) -join ', '
            throw "workflow selector '$selector' is ambiguous remotely. Matches: $paths"
        }
        if ($selectedLocal.Count -eq 0 -and $selectedRemote.Count -eq 0) {
            throw "workflow '$selector' was not found locally or remotely for '$($context.FullName)'."
        }
    }

    $structuralFailures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($workflow in $selectedLocal) {
        $errors = @(Test-ActionWorkflowLocalWorkflow $workflow)
        if ($errors.Count -gt 0) {
            $structuralFailures.Add("$($workflow.Path): $($errors -join ' ')")
        }
    }
    if ($structuralFailures.Count -gt 0) {
        throw ("local workflow validation failed:`n - " + ($structuralFailures.ToArray() -join "`n - "))
    }

    $remoteByPath = @{}
    foreach ($remote in $selectedRemote) {
        $key = ([string]$remote.path).Replace('\', '/').ToLowerInvariant()
        $remoteByPath[$key] = $remote
    }

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $strictFailures = New-Object 'System.Collections.Generic.List[string]'
    $matchedRemotePaths = New-Object 'System.Collections.Generic.HashSet[string]'
    $nameCounts = @{}

    foreach ($local in $selectedLocal) {
        if ($nameCounts.ContainsKey([string]$local.Name)) {
            $nameCounts[[string]$local.Name]++
        }
        else {
            $nameCounts[[string]$local.Name] = 1
        }

        $key = ([string]$local.Path).ToLowerInvariant()
        $remote = $null
        if ($remoteByPath.ContainsKey($key)) {
            $remote = $remoteByPath[$key]
            [void]$matchedRemotePaths.Add($key)
        }

        if ($null -eq $remote) {
            Write-Output "PASS $($local.Path) | $($local.Name) | local only"
            $warnings.Add("$($local.Path) is not registered on GitHub yet; commit and push it first.")
            if ($options.requireRemote) {
                $strictFailures.Add("$($local.Path) is not registered on GitHub.")
            }
            continue
        }

        $stateLabel = [string]$remote.state
        if ($stateLabel -ieq 'disabled') {
            $warnings.Add("$($local.Path) is registered but disabled on GitHub.")
        }
        if ([string]$remote.name -ine $local.Name) {
            $warnings.Add("$($local.Path) has local name '$($local.Name)' but remote name '$($remote.name)'.")
        }
        Write-Output "PASS $($local.Path) | $($local.Name) | registered ($stateLabel)"
    }

    foreach ($name in @($nameCounts.Keys)) {
        if ([int]$nameCounts[$name] -gt 1) {
            $warnings.Add("multiple selected local workflows are named '$name'; select by path or id.")
        }
    }

    if ([string]::IsNullOrWhiteSpace($selector)) {
        foreach ($remote in $selectedRemote) {
            $key = ([string]$remote.path).Replace('\', '/').ToLowerInvariant()
            if (-not $matchedRemotePaths.Contains($key)) {
                $warnings.Add("remote workflow '$($remote.name)' [$($remote.path)] has no local workflow file at that path.")
            }
        }
    }
    elseif ($selectedLocal.Count -eq 0 -and $selectedRemote.Count -eq 1) {
        $warnings.Add("workflow '$selector' exists remotely but has no local workflow file at '$($selectedRemote[0].path)'.")
    }

    if ($strictFailures.Count -gt 0) {
        throw ("workflow validation failed:`n - " + ($strictFailures.ToArray() -join "`n - "))
    }

    Write-Output "Repository: $($context.FullName) | branch: $($context.Branch) | gh: $($context.GhLogin)"
    if (-not [string]::IsNullOrWhiteSpace($selector)) {
        Write-Output "Workflow filter: $selector"
    }
    Write-Output "Local workflows: $($selectedLocal.Count) | Remote workflows: $($selectedRemote.Count)"

    foreach ($warning in $warnings) {
        Write-Output "WARNING: $warning"
    }

    if ($warnings.Count -eq 0) {
        Write-Output "Validation passed: $($selectedLocal.Count) local workflow(s) checked, no warnings."
    }
    else {
        Write-Output "Validation passed with $($warnings.Count) warning(s)."
    }
}

function Invoke-ActionWorkflowStatus {
    param([string[]]$Arguments)

    if ($Arguments -contains '-h' -or $Arguments -contains '--help') {
        Show-ActionWorkflowStatusHelp
        return
    }

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{ '--workflow' = 'workflow'; '--branch' = 'branch'; '--limit' = 'limit' } `
        -SwitchOptions @{ '--all-branches' = 'allBranches' }

    $limit = 10
    if (-not [string]::IsNullOrWhiteSpace([string]$options.limit)) {
        $limit = ConvertTo-ActionWorkflowPositiveInteger -Value ([string]$options.limit) -Name '--limit' -Maximum 100
    }
    $context = Get-ActionWorkflowContext
    $branch = ConvertTo-ActionWorkflowBranchFilter -Branch ([string]$options.branch) -AllBranches:([bool]$options.allBranches)
    if (-not $options.allBranches -and [string]::IsNullOrWhiteSpace($branch)) {
        $branch = $context.Branch
    }

    $workflow = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$options.workflow)) {
        $workflow = Resolve-ActionWorkflow $context ([string]$options.workflow)
    }

    $runs = @(Get-ActionWorkflowRuns -Context $context -Workflow $workflow -Branch $branch `
        -AllBranches:([bool]$options.allBranches) -Limit $limit |
        Sort-Object -Property createdAt -Descending)

    $branchLabel = if ($options.allBranches) { 'all branches' } else { $branch }
    $workflowLabel = if ($null -ne $workflow) { "$($workflow.name) [$($workflow.path)]" } else { 'all workflows' }

    Write-Output "Repository: $($context.FullName)"
    Write-Output "Branch: $branchLabel | Workflow: $workflowLabel | Limit: $limit"

    if ($runs.Count -eq 0) {
        $scopeLabel = if ($options.allBranches) { 'all branches' } else { "branch '$branch'" }
        if ($null -ne $workflow) {
            Write-Output "No workflow runs found for $scopeLabel and workflow '$($workflow.name)' [$($workflow.path)]."
        }
        else {
            Write-Output "No workflow runs found for $scopeLabel."
        }
        return
    }

    $header = (@(
        (Format-ActionWorkflowColumn 'RUN' 12),
        (Format-ActionWorkflowColumn 'WORKFLOW' 22),
        (Format-ActionWorkflowColumn 'BRANCH' 16),
        (Format-ActionWorkflowColumn 'STATUS' 18),
        (Format-ActionWorkflowColumn 'CREATED' 16),
        (Format-ActionWorkflowColumn 'TITLE' 30)
    ) -join ' ')
    Write-Output ''
    Write-Output $header
    Write-Output ('-' * $header.Length)

    foreach ($run in $runs) {
        $line = (@(
            (Format-ActionWorkflowColumn ([string]$run.databaseId) 12),
            (Format-ActionWorkflowColumn ([string]$run.workflowName) 22),
            (Format-ActionWorkflowColumn ([string]$run.headBranch) 16),
            (Format-ActionWorkflowColumn (Format-ActionWorkflowStatusLabel $run) 18),
            (Format-ActionWorkflowColumn (Format-ActionWorkflowTimestamp ([string]$run.createdAt)) 16),
            (Format-ActionWorkflowColumn ([string]$run.displayTitle) 30)
        ) -join ' ')
        Write-Output $line
    }
}

function Resolve-ActionWorkflowSelectedRun {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Options
    )

    $branch = ConvertTo-ActionWorkflowBranchFilter -Branch ([string]$Options.branch) -AllBranches:([bool]$Options.allBranches)
    if ([string]::IsNullOrWhiteSpace([string]$Options.run) -and -not $Options.allBranches -and [string]::IsNullOrWhiteSpace($branch)) {
        $branch = $Context.Branch
    }

    $workflow = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Options.workflow)) {
        $workflow = Resolve-ActionWorkflow $Context ([string]$Options.workflow)
    }

    $workflowSelector = ''
    if ($null -ne $workflow) {
        $workflowSelector = [string]$workflow.path
    }

    $run = Resolve-ActionWorkflowRun -Context $Context -RunId ([string]$Options.run) `
        -WorkflowSelector $workflowSelector -Branch $branch -AllBranches:([bool]$Options.allBranches)

    [pscustomobject]@{
        Run      = $run
        Workflow = $workflow
        Branch   = $branch
    }
}

function Invoke-ActionWorkflowWatch {
    param([string[]]$Arguments)

    if ($Arguments -contains '-h' -or $Arguments -contains '--help') {
        Show-ActionWorkflowWatchHelp
        return
    }

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{
            '--run' = 'run'
            '--workflow' = 'workflow'
            '--branch' = 'branch'
            '--interval' = 'interval'
            '--timeout' = 'timeout'
        } `
        -SwitchOptions @{ '--all-branches' = 'allBranches' }

    $interval = 10
    $timeout = 600
    if (-not [string]::IsNullOrWhiteSpace([string]$options.interval)) {
        $interval = ConvertTo-ActionWorkflowPositiveInteger -Value ([string]$options.interval) -Name '--interval' -Minimum 1 -Maximum 300
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$options.timeout)) {
        $timeout = ConvertTo-ActionWorkflowPositiveInteger -Value ([string]$options.timeout) -Name '--timeout' -Minimum 1 -Maximum 86400
    }

    $context = Get-ActionWorkflowContext
    $selection = Resolve-ActionWorkflowSelectedRun -Context $context -Options $options
    $run = $selection.Run

    Write-Output "Repository: $($context.FullName)"
    Write-ActionWorkflowRunDetails $run
    Write-Output ''

    $label = Format-ActionWorkflowStatusLabel $run
    if ([string]$run.status -eq 'completed') {
        Write-Output "Run $($run.databaseId) is already completed: $label"
        $script:ExitCode = Get-ActionWorkflowRunExitCode $run
        return
    }

    Write-Output "Watching run $($run.databaseId) every $interval second(s), timeout $timeout second(s)."
    $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
    $lastLabel = $label

    while ($true) {
        $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -le 0) {
            throw "timed out after $timeout second(s) waiting for run $($run.databaseId) to finish. Run URL: $($run.url)"
        }

        $sleepSeconds = [Math]::Min($interval, [Math]::Max(1, [Math]::Ceiling($remaining)))
        Start-Sleep -Seconds ([int]$sleepSeconds)

        $run = Get-ActionWorkflowRun $context ([string]$run.databaseId)
        $label = Format-ActionWorkflowStatusLabel $run
        if ($label -cne $lastLabel) {
            Write-Output "Updated: $([DateTime]::Now.ToString('HH:mm:ss')) | $label"
            $lastLabel = $label
        }

        if ([string]$run.status -eq 'completed') {
            Write-Output "Run $($run.databaseId) finished: $label"
            $script:ExitCode = Get-ActionWorkflowRunExitCode $run
            return
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            throw "timed out after $timeout second(s) waiting for run $($run.databaseId) to finish. Run URL: $($run.url)"
        }
    }
}

function Invoke-ActionWorkflowLogs {
    param([string[]]$Arguments)

    if ($Arguments -contains '-h' -or $Arguments -contains '--help') {
        Show-ActionWorkflowLogsHelp
        return
    }

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{
            '--run' = 'run'
            '--workflow' = 'workflow'
            '--branch' = 'branch'
            '--job' = 'job'
        } `
        -SwitchOptions @{
            '--all-branches' = 'allBranches'
            '--failed' = 'failed'
        }

    $context = Get-ActionWorkflowContext
    $selection = Resolve-ActionWorkflowSelectedRun -Context $context -Options $options
    $run = $selection.Run

    $job = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$options.job)) {
        $job = Resolve-ActionWorkflowJob -Context $context -Run $run -JobId ([string]$options.job)
    }

    if ($options.failed) {
        $failedJobs = @(Get-ActionWorkflowFailedJobs -Context $context -Run $run)
        if ($null -ne $job) {
            $selectedFailed = @($failedJobs | Where-Object { [string]$_.databaseId -eq [string]$job.databaseId })
            if ($selectedFailed.Count -eq 0) {
                throw "job '$($job.databaseId)' has no failed steps to show."
            }
        }
        elseif ($failedJobs.Count -eq 0) {
            throw "workflow run '$($run.databaseId)' has no failed jobs to show."
        }
    }

    $logArguments = @('run', 'view', [string]$run.databaseId, '--repo', $context.RepoSpec)
    if ($null -ne $job) {
        $logArguments += @('--job', [string]$job.databaseId)
    }
    if ($options.failed) {
        $logArguments += '--log-failed'
    }
    else {
        $logArguments += '--log'
    }

    $result = Invoke-ActionWorkflowGh $logArguments
    if ($result.ExitCode -ne 0) {
        throw "could not retrieve logs for workflow run '$($run.databaseId)'.`n$(Format-ActionWorkflowFailure $result)"
    }

    Write-Output "Repository: $($context.FullName)"
    Write-Output "Run:        $($run.databaseId)"
    Write-Output "Workflow:   $($run.workflowName)"
    Write-Output "Branch:     $($run.headBranch)"
    Write-Output "Status:     $(Format-ActionWorkflowStatusLabel $run)"
    if ($null -ne $job) {
        Write-Output "Job:        $($job.databaseId) ($($job.name))"
    }
    $modeLabel = if ($options.failed) { 'failed steps' } else { 'full logs' }
    Write-Output "Logs:       $modeLabel"
    Write-Output ''

    $lines = @($result.Output | ForEach-Object { [string]$_ })
    if ($lines.Count -eq 0 -or (($lines -join '').Trim().Length -eq 0)) {
        Write-Output '(no log output returned)'
        return
    }
    foreach ($line in $lines) {
        Write-Output $line
    }
}

function Invoke-ActionWorkflowRetry {
    param([string[]]$Arguments)

    if ($Arguments -contains '-h' -or $Arguments -contains '--help') {
        Show-ActionWorkflowRetryHelp
        return
    }

    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{
            '--run' = 'run'
            '--workflow' = 'workflow'
            '--branch' = 'branch'
        } `
        -SwitchOptions @{
            '--all-branches' = 'allBranches'
            '--all' = 'all'
            '--yes' = 'yes'
        }

    $context = Get-ActionWorkflowContext
    $selection = Resolve-ActionWorkflowSelectedRun -Context $context -Options $options
    $run = $selection.Run

    if ([string]$run.status -ne 'completed') {
        throw "workflow run '$($run.databaseId)' is $(Format-ActionWorkflowStatusLabel $run); wait for it to finish before retrying."
    }

    $retryableConclusions = @('failure', 'timed_out', 'action_required', 'startup_failure', 'cancelled')
    if ([string]$run.conclusion -notin $retryableConclusions) {
        throw "workflow run '$($run.databaseId)' concluded '$($run.conclusion)' and cannot be retried."
    }

    $failedJobs = @()
    if (-not $options.all) {
        $failedJobs = @(Get-ActionWorkflowFailedJobs -Context $context -Run $run)
        if ($failedJobs.Count -eq 0) {
            throw "workflow run '$($run.databaseId)' has no failed jobs to re-run. Use --all to re-run every job."
        }
    }

    Write-Output "Repository: $($context.FullName)"
    Write-ActionWorkflowRunDetails $run
    if (-not $options.all) {
        $jobNames = @($failedJobs | ForEach-Object { "$($_.name) ($($_.databaseId))" }) -join ', '
        Write-Output "Failed jobs: $($failedJobs.Count) [$jobNames]"
    }

    $actionLabel = if ($options.all) { 'all jobs' } else { 'failed jobs' }
    if (-not $options.yes) {
        $prompt = "Re-run $actionLabel for run $($run.databaseId) on branch '$($run.headBranch)'? [y/N]"
        if ([Console]::IsInputRedirected) {
            Write-Output $prompt
            $answer = [Console]::In.ReadLine()
        }
        else {
            $answer = Read-Host -Prompt $prompt
        }
        if ($null -eq $answer) {
            throw 'confirmation is required; run the command interactively or pass --yes.'
        }
        if ($answer.Trim() -notmatch '^(?i:y|yes)$') {
            throw 'retry cancelled.'
        }
    }

    $rerunArguments = @('run', 'rerun', [string]$run.databaseId, '--repo', $context.RepoSpec)
    if (-not $options.all) {
        $rerunArguments += '--failed'
    }
    $result = Invoke-ActionWorkflowGh $rerunArguments
    if ($result.ExitCode -ne 0) {
        throw "could not re-run workflow run '$($run.databaseId)'.`n$(Format-ActionWorkflowFailure $result)"
    }

    Write-Output ''
    Write-Output "Requested $actionLabel re-run for workflow run $($run.databaseId)."
    Write-Output "Run URL: $($run.url)"
    Write-Output "Track: $($script:CommandPrefix) watch --run $($run.databaseId)"
}

$corePath = Join-Path $PSScriptRoot 'git-action-workflow-core.ps1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    [Console]::Error.WriteLine("$($script:CommandPrefix): missing required file: $corePath")
    exit 1
}

try {
    . $corePath
}
catch {
    [Console]::Error.WriteLine("$($script:CommandPrefix): could not load the shared engine: $($_.Exception.Message)")
    exit 1
}

try {
    if ($args.Count -eq 0) {
        Show-ActionWorkflowUsage
        exit 1
    }

    $script:ExitCode = 0
    $command = [string]$args[0]
    $commandArguments = @()
    if ($args.Count -gt 1) {
        $commandArguments = [string[]]$args[1..($args.Count - 1)]
    }

    switch -Regex ($command.ToLowerInvariant()) {
        '^(?:-h|--help|help)$' {
            Show-ActionWorkflowUsage
            exit 0
        }
        '^init$' {
            Invoke-ActionWorkflowInit $commandArguments
            exit [int]$script:ExitCode
        }
        '^validate$' {
            Invoke-ActionWorkflowValidate $commandArguments
            exit [int]$script:ExitCode
        }
        '^status$' {
            Invoke-ActionWorkflowStatus $commandArguments
            exit [int]$script:ExitCode
        }
        '^watch$' {
            Invoke-ActionWorkflowWatch $commandArguments
            exit [int]$script:ExitCode
        }
        '^logs$' {
            Invoke-ActionWorkflowLogs $commandArguments
            exit [int]$script:ExitCode
        }
        '^retry$' {
            Invoke-ActionWorkflowRetry $commandArguments
            exit [int]$script:ExitCode
        }
        default {
            throw "unknown command '$command'. Run '$($script:CommandPrefix) -h' for usage."
        }
    }
}
catch {
    [Console]::Error.WriteLine("$($script:CommandPrefix): $($_.Exception.Message)")
    exit 1
}
