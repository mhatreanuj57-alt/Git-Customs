function Show-GitPrFlowUsage {
    Write-Output 'Usage: git pr-flow [command] [options]'
    Write-Output ''
    Write-Output 'Inspect pull requests and CI checks, or create a pull request without pushing.'
    Write-Output ''
    Write-Output 'Commands:'
    Write-Output '  status  Show the pull request for the current or selected branch (default)'
    Write-Output '  create  Create a pull request after confirmation'
    Write-Output '  checks  Show pull request checks, optionally waiting for completion'
    Write-Output ''
    Write-Output "Run '$($script:CommandPrefix) <command> -h' for command options."
}

function Show-GitPrFlowStatusHelp {
    Write-Output 'Usage: git pr-flow status [--number <id>] [--branch <name>]'
    Write-Output ''
    Write-Output 'Shows pull request metadata and a CI check summary. Read-only.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --number <id>    Select a pull request by number'
    Write-Output '  --branch <name>  Select a pull request by head branch (default: current branch)'
}

function Show-GitPrFlowCreateHelp {
    Write-Output 'Usage: git pr-flow create --title <title> [--body <text>] [--body-file <path>] [--base <branch>] [--draft] [--yes]'
    Write-Output ''
    Write-Output 'Creates a pull request for the current branch. The branch must already be'
    Write-Output 'pushed and exactly match origin/<branch>; this command never pushes.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --title <title>      Pull request title (required, 1-256 characters)'
    Write-Output '  --body <text>        Pull request body'
    Write-Output '  --body-file <path>   Read the body from a UTF-8 file'
    Write-Output '  --base <branch>      Base branch (default: repository default branch)'
    Write-Output '  --draft              Create the pull request as a draft'
    Write-Output '  --yes                Skip the interactive confirmation prompt'
}

function Show-GitPrFlowChecksHelp {
    Write-Output 'Usage: git pr-flow checks [--number <id>] [--branch <name>] [--watch] [--interval <seconds>] [--timeout <seconds>]'
    Write-Output ''
    Write-Output 'Shows status checks for a pull request. --watch polls until checks complete'
    Write-Output 'or the timeout expires. Read-only.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --number <id>        Select a pull request by number'
    Write-Output '  --branch <name>      Select a pull request by head branch (default: current branch)'
    Write-Output '  --watch              Poll until checks finish or timeout'
    Write-Output '  --interval <seconds> Poll interval (1-300, default: 10)'
    Write-Output '  --timeout <seconds>  Maximum wait (1-7200, default: 600)'
    Write-Output ''
    Write-Output 'Exit codes: 0 for passing or no checks; 1 for pending, failing, or timeout.'
}

function Assert-GitPrFlowSelectors {
    param($Options)

    if ($Options.ContainsKey('Number') -and $Options.ContainsKey('Branch')) {
        throw '--number and --branch cannot be used together.'
    }
    if ($Options.ContainsKey('Number')) {
        $number = 0
        if (-not [int]::TryParse([string]$Options['Number'], [ref]$number) -or $number -lt 1) {
            throw '--number must be a positive integer.'
        }
        return [string]$number
    }
    if ($Options.ContainsKey('Branch')) {
        return (Assert-GitCommandBranchName ([string]$Options['Branch']))
    }
    return $null
}

function Get-GitPrFlowPr {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$Selector,
        [string]$Branch
    )

    $target = $Selector
    if ([string]::IsNullOrWhiteSpace($target)) {
        if ([string]::IsNullOrWhiteSpace($Branch)) {
            $Branch = $Context.Branch
        }
        $target = $Branch
    }
    if ([string]::IsNullOrWhiteSpace($target) -or $target.StartsWith('-')) {
        throw 'a pull request number or branch is required.'
    }

    return (Read-GitCommandGhJson -Arguments @(
        'pr', 'view', $target,
        '--repo', $Context.RepoSpec,
        '--json', 'number,title,state,url,headRefName,baseRefName,isDraft,mergeable,reviewDecision,statusCheckRollup'
    ) -Description "pull request '$target'")
}

function Get-GitPrFlowCheckBucket {
    param($Check)

    $conclusion = ([string]$Check.conclusion).ToLowerInvariant()
    $state = ([string]$Check.state).ToLowerInvariant()
    $status = ([string]$Check.status).ToLowerInvariant()

    if ($conclusion -in @('success', 'neutral', 'skipped')) { return 'pass' }
    if ($conclusion -in @('failure', 'cancelled', 'timed_out', 'action_required', 'startup_failure', 'error')) { return 'fail' }
    if ($state -eq 'success') { return 'pass' }
    if ($state -in @('failure', 'error')) { return 'fail' }
    if ($state -eq 'expected' -or $status -in @('queued', 'in_progress', 'waiting', 'requested', 'pending') -or $state -eq 'pending') { return 'pending' }
    if ([string]::IsNullOrWhiteSpace($status) -and [string]::IsNullOrWhiteSpace($state) -and [string]::IsNullOrWhiteSpace($conclusion)) { return 'pending' }
    return 'pending'
}

function Get-GitPrFlowCheckSummary {
    param($Pr)

    $checks = @()
    if ($null -ne $Pr -and $null -ne $Pr.statusCheckRollup) {
        $checks = @($Pr.statusCheckRollup)
    }
    $summary = [ordered]@{
        Total   = $checks.Count
        Passed  = 0
        Failed  = 0
        Pending = 0
        Items   = @()
    }
    foreach ($check in $checks) {
        $bucket = Get-GitPrFlowCheckBucket $check
        if ($bucket -eq 'pass') { $summary.Passed++ }
        elseif ($bucket -eq 'fail') { $summary.Failed++ }
        else { $summary.Pending++ }

        $name = [string]$check.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$check.context }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$check.workflowName }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(unnamed check)' }
        $link = [string]$check.detailsUrl
        if ([string]::IsNullOrWhiteSpace($link)) { $link = [string]$check.targetUrl }

        $summary.Items += [pscustomobject]@{
            Name    = $name
            Bucket  = $bucket
            Status  = if (-not [string]::IsNullOrWhiteSpace([string]$check.conclusion)) { [string]$check.conclusion } elseif (-not [string]::IsNullOrWhiteSpace([string]$check.state)) { [string]$check.state } else { [string]$check.status }
            Link    = $link
        }
    }
    return [pscustomobject]$summary
}

function Write-GitPrFlowPr {
    param($Pr)

    $draft = ''
    if ($Pr.isDraft -eq $true) { $draft = ', draft' }
    Write-Output "#$($Pr.number) $($Pr.title) [$($Pr.state)$draft]"
    Write-Output $Pr.url
    Write-Output "$($Pr.headRefName) -> $($Pr.baseRefName) | mergeable: $($Pr.mergeable) | review: $($Pr.reviewDecision)"
    $checks = Get-GitPrFlowCheckSummary $Pr
    Write-Output "Checks: $($checks.Passed) passed, $($checks.Pending) pending, $($checks.Failed) failed ($($checks.Total) total)."
    foreach ($item in @($checks.Items)) {
        if ($item.Bucket -eq 'pass') { continue }
        $suffix = ''
        if (-not [string]::IsNullOrWhiteSpace($item.Link)) {
            $suffix = " - $($item.Link)"
        }
        Write-Output ("  {0,-7} {1}{2}" -f $item.Bucket.ToUpperInvariant(), $item.Name, $suffix)
    }
}

function Invoke-GitPrFlowStatus {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitPrFlowStatusHelp
        return
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{ '--number' = 'Number'; '--branch' = 'Branch' } `
        -SwitchOptions @{}
    $selector = Assert-GitPrFlowSelectors $options
    $context = Get-ActionWorkflowContext
    $pr = Get-GitPrFlowPr -Context $context -Selector $selector
    if ($null -eq $pr) {
        throw 'pull request not found.'
    }
    Write-GitPrFlowPr $pr
    $checks = Get-GitPrFlowCheckSummary $pr
    if ($checks.Failed -gt 0 -or $checks.Pending -gt 0) {
        $script:ExitCode = 1
    }
}

function Invoke-GitPrFlowChecks {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitPrFlowChecksHelp
        return
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{
            '--number' = 'Number'
            '--branch' = 'Branch'
            '--interval' = 'Interval'
            '--timeout' = 'Timeout'
        } `
        -SwitchOptions @{ '--watch' = 'Watch' }
    $selector = Assert-GitPrFlowSelectors $options
    $interval = 10
    $timeout = 600
    if ($options.ContainsKey('Interval')) {
        $interval = ConvertTo-ActionWorkflowPositiveInteger ([string]$options['Interval']) '--interval' 1 300
    }
    if ($options.ContainsKey('Timeout')) {
        $timeout = ConvertTo-ActionWorkflowPositiveInteger ([string]$options['Timeout']) '--timeout' 1 7200
    }

    $context = Get-ActionWorkflowContext
    $started = Get-Date
    $lastLine = ''
    while ($true) {
        $pr = Get-GitPrFlowPr -Context $context -Selector $selector
        $checks = Get-GitPrFlowCheckSummary $pr
        $summary = "Checks: $($checks.Passed) passed, $($checks.Pending) pending, $($checks.Failed) failed ($($checks.Total) total)."
        Write-Output "#$($pr.number) $($pr.title)"
        Write-Output $summary
        foreach ($item in @($checks.Items)) {
            if ($item.Bucket -eq 'pass') { continue }
            Write-Output ("  {0,-7} {1}" -f $item.Bucket.ToUpperInvariant(), $item.Name)
        }

        if (-not $options.ContainsKey('Watch')) {
            if ($checks.Failed -gt 0 -or $checks.Pending -gt 0) {
                $script:ExitCode = 1
            }
            return
        }

        if ($checks.Pending -eq 0) {
            if ($checks.Failed -gt 0) {
                Write-Output 'Checks finished with failures.'
                $script:ExitCode = 1
            }
            else {
                Write-Output 'All checks completed successfully.'
                $script:ExitCode = 0
            }
            return
        }

        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        if ($elapsed -ge $timeout) {
            Write-Output "Timed out after $timeout second(s) with $($checks.Pending) check(s) still pending."
            $script:ExitCode = 1
            return
        }
        Start-Sleep -Seconds ([Math]::Min($interval, [Math]::Max(1, $timeout - $elapsed)))
    }
}

function Invoke-GitPrFlowCreate {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitPrFlowCreateHelp
        return
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{
            '--title' = 'Title'
            '--body' = 'Body'
            '--body-file' = 'BodyFile'
            '--base' = 'Base'
        } `
        -SwitchOptions @{ '--draft' = 'Draft'; '--yes' = 'Yes' }

    if (-not $options.ContainsKey('Title')) {
        throw '--title is required.'
    }
    $title = ([string]$options['Title']).Trim()
    if ([string]::IsNullOrWhiteSpace($title) -or $title.Length -gt 256 -or $title -match '[\r\n]') {
        throw '--title must be a single line between 1 and 256 characters.'
    }
    if ($options.ContainsKey('Body') -and $options.ContainsKey('BodyFile')) {
        throw '--body and --body-file cannot be used together.'
    }

    $body = ''
    if ($options.ContainsKey('Body')) {
        $body = [string]$options['Body']
    }
    elseif ($options.ContainsKey('BodyFile')) {
        $bodyPath = [string]$options['BodyFile']
        if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
            throw "body file does not exist: $bodyPath"
        }
        $body = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $bodyPath).ProviderPath)
    }
    if ($body.Length -gt 65536) {
        throw 'pull request body must be 65536 characters or fewer.'
    }

    $context = Get-ActionWorkflowContext
    $info = Get-GitCommandRepoInfo -RepoRoot $context.RepoRoot
    if ($info.Detached) {
        throw 'repository is in a detached HEAD state; check out the branch to create a pull request.'
    }

    $base = ''
    if ($options.ContainsKey('Base')) {
        $base = Assert-GitCommandBranchName ([string]$options['Base'])
    }
    else {
        $repoData = Read-GitCommandGhJson -Arguments @('repo', 'view', $context.RepoSpec, '--json', 'defaultBranchRef') -Description 'repository default branch'
        if ($null -eq $repoData -or $null -eq $repoData.defaultBranchRef) {
            throw 'could not determine the repository default branch.'
        }
        $base = [string]$repoData.defaultBranchRef.name
    }
    if ([string]::IsNullOrWhiteSpace($base) -or $base.StartsWith('-')) {
        throw 'the base branch is not valid.'
    }
    if ($base -ieq $info.Branch) {
        throw "the base branch cannot be the current branch '$($info.Branch)'."
    }

    $baseRemote = Invoke-GitCommand -RepoRoot $context.RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$base") -AllowFailure
    if ($baseRemote.ExitCode -ne 0) {
        throw "base branch 'origin/$base' was not found locally; fetch it before creating a pull request."
    }
    $headRemote = Get-GitCommandRemoteTrackingSha -RepoRoot $context.RepoRoot -Branch $info.Branch
    if ([string]::IsNullOrWhiteSpace($headRemote)) {
        throw "branch '$($info.Branch)' has not been pushed to origin. Push it first; this command never pushes."
    }
    if ($headRemote -ne $info.Head) {
        throw "local branch '$($info.Branch)' does not match origin/$($info.Branch). Push it first; this command never pushes."
    }

    $existingRaw = Read-GitCommandGhJson -Arguments @(
        'pr', 'list',
        '--repo', $context.RepoSpec,
        '--head', $info.Branch,
        '--state', 'open',
        '--json', 'number,url,title,isDraft'
    ) -Description 'open pull request lookup'
    $existing = @()
    if ($null -ne $existingRaw) {
        $existing = @($existingRaw)
    }
    if ($existing.Count -gt 0) {
        throw "an open pull request already exists for '$($info.Branch)': $($existing[0].url)"
    }

    Write-Output "Repository: $($context.RepoSpec)"
    Write-Output "Pull request: $($info.Branch) -> $base"
    Write-Output "Title: $title"
    if ($options.ContainsKey('Draft')) {
        Write-Output 'Draft: yes'
    }
    if (-not $options.ContainsKey('Yes')) {
        $approved = Read-GitCommandConfirmation 'Create this pull request? Type y to continue:'
        if (-not $approved) {
            Write-Output 'Cancelled.'
            return
        }
    }

    $ghArguments = @(
        'pr', 'create',
        '--repo', $context.RepoSpec,
        '--head', $info.Branch,
        '--base', $base,
        "--title=$title",
        "--body=$body"
    )
    if ($options.ContainsKey('Draft')) {
        $ghArguments += '--draft'
    }
    $result = Invoke-GitCommandGh -Arguments $ghArguments
    foreach ($line in @($result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Output ([string]$line)
        }
    }
    Write-Output 'Pull request created.'
}
