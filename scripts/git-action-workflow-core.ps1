$ErrorActionPreference = 'Continue'

$env:GH_PAGER = 'cat'
$env:GH_PROMPT_DISABLED = '1'
$env:GH_NO_UPDATE_NOTIFIER = '1'
$env:NO_COLOR = '1'

$script:ActionWorkflowAuthCache = @{}

function Invoke-ActionWorkflowGitDetect {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & git --no-optional-locks @Arguments 2>$null
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = [string[]]@($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-ActionWorkflowGh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & gh @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = [string[]]@($output | ForEach-Object { [string]$_ })
            Error    = $stderr
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Format-ActionWorkflowFailure {
    param([Parameter(Mandatory = $true)]$Result)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($Result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            $lines.Add(([string]$line).TrimEnd())
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) {
        $lines.Add(([string]$Result.Error).TrimEnd())
    }

    if ($lines.Count -eq 0) {
        return 'GitHub CLI did not provide an error message.'
    }

    return ($lines -join "`n")
}

function ConvertTo-ActionWorkflowPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function ConvertFrom-ActionWorkflowGhJson {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Result.ExitCode -ne 0) {
        throw "$Description failed.`n$(Format-ActionWorkflowFailure $Result)"
    }

    $text = (($Result.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "$Description returned invalid JSON."
    }
}

function Assert-ActionWorkflowGitAvailable {
    $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCommand) {
        throw 'Git is not installed or is not available on PATH.'
    }
    return $gitCommand
}

function Assert-ActionWorkflowGhAvailable {
    $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ghCommand) {
        throw 'GitHub CLI (gh) is not installed or is not available on PATH.'
    }
    return $ghCommand
}

function ConvertTo-ActionWorkflowGitHubRemoteInfo {
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $value = $RemoteUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'the origin remote URL is empty.'
    }

    $hostName = $null
    $remotePath = $null

    if ($value -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        try {
            $uri = [System.Uri]$value
        }
        catch {
            throw 'the origin remote is not a valid URL.'
        }

        if (-not $uri.IsAbsoluteUri) {
            throw 'the origin remote is not a valid URL.'
        }

        $hostName = $uri.Host
        $remotePath = $uri.AbsolutePath
    }
    elseif ($value -match '^(?:[^@/\s]+@)?(?<host>[^:/\s\\]+):(?<path>.+)$') {
        $hostName = $Matches['host']
        $remotePath = $Matches['path']
    }
    else {
        throw 'the origin remote is not a supported GitHub HTTPS or SSH URL.'
    }

    if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName -notmatch '^[A-Za-z0-9.-]+$') {
        throw 'the origin remote has an invalid GitHub host.'
    }

    $remotePath = ([string]$remotePath).Trim().Trim('/')
    if ($remotePath.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $remotePath = $remotePath.Substring(0, $remotePath.Length - 4)
    }

    $segments = @($remotePath -split '/')
    if ($segments.Count -ne 2) {
        throw 'the origin remote must point to a GitHub owner/repository pair.'
    }

    try {
        $owner = [System.Uri]::UnescapeDataString($segments[0])
        $repository = [System.Uri]::UnescapeDataString($segments[1])
    }
    catch {
        throw 'the origin remote contains invalid owner or repository characters.'
    }

    if ($owner -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
        throw 'the origin remote has an invalid GitHub owner name.'
    }
    if ($repository -notmatch '^[A-Za-z0-9._-]+$' -or $repository -eq '.' -or $repository -eq '..') {
        throw 'the origin remote has an invalid GitHub repository name.'
    }

    $hostName = $hostName.ToLowerInvariant()
    $fullName = "$owner/$repository"
    $repoSpec = $fullName
    if ($hostName -ne 'github.com') {
        $repoSpec = "$hostName/$fullName"
    }

    [pscustomobject]@{
        Host      = $hostName
        Owner     = $owner
        Name      = $repository
        FullName  = $fullName
        RepoSpec  = $repoSpec
        RemoteUrl = $RemoteUrl
    }
}

function Get-ActionWorkflowRepositoryContext {
    Assert-ActionWorkflowGitAvailable | Out-Null

    $repoCheck = Invoke-ActionWorkflowGitDetect @('rev-parse', '--is-inside-work-tree')
    if ($repoCheck.ExitCode -ne 0 -or (($repoCheck.Output -join '').Trim() -ne 'true')) {
        throw 'not inside a Git working tree.'
    }

    $rootResult = Invoke-ActionWorkflowGitDetect @('rev-parse', '--show-toplevel')
    if ($rootResult.ExitCode -ne 0) {
        throw 'could not determine the repository root.'
    }

    $repoRoot = ($rootResult.Output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'could not determine the repository root.'
    }

    $originResult = Invoke-ActionWorkflowGitDetect @('-C', $repoRoot, 'remote', 'get-url', 'origin')
    $originUrl = ($originResult.Output -join '').Trim()
    if ($originResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) {
        throw 'repository has no origin remote configured.'
    }

    $remote = ConvertTo-ActionWorkflowGitHubRemoteInfo $originUrl

    $branchResult = Invoke-ActionWorkflowGitDetect @('-C', $repoRoot, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    $branch = ($branchResult.Output -join '').Trim()
    if ($branchResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw 'repository is in a detached HEAD state; check out a branch first.'
    }

    $headProbe = Invoke-ActionWorkflowGitDetect @('-C', $repoRoot, 'rev-parse', '--verify', '--quiet', 'HEAD')
    $hasHead = ($headProbe.ExitCode -eq 0)

    [pscustomobject]@{
        RepoRoot  = $repoRoot
        RepoName  = $remote.Name
        Owner     = $remote.Owner
        Host      = $remote.Host
        FullName  = $remote.FullName
        RepoSpec  = $remote.RepoSpec
        OriginUrl = $remote.RemoteUrl
        Branch    = $branch
        HasHead   = $hasHead
    }
}

function Assert-ActionWorkflowGhAuthenticated {
    param([Parameter(Mandatory = $true)][string]$HostName)

    Assert-ActionWorkflowGhAvailable | Out-Null

    $cacheKey = $HostName.ToLowerInvariant()
    if ($script:ActionWorkflowAuthCache.ContainsKey($cacheKey)) {
        return $script:ActionWorkflowAuthCache[$cacheKey]
    }

    $result = Invoke-ActionWorkflowGh @('auth', 'status', '--json', 'hosts', '--hostname', $HostName)
    if ($result.ExitCode -ne 0) {
        throw "could not check gh authentication for '$HostName'.`n$(Format-ActionWorkflowFailure $result)"
    }

    $payload = ConvertFrom-ActionWorkflowGhJson $result "gh authentication check for '$HostName'"
    $accounts = @()
    if ($null -ne $payload -and $null -ne $payload.hosts) {
        foreach ($property in @($payload.hosts.PSObject.Properties)) {
            if ($property.Name -ieq $HostName) {
                $accounts = @($property.Value)
                break
            }
        }
    }

    $active = @($accounts | Where-Object { $_.active -eq $true })
    if ($active.Count -eq 0) {
        throw "gh has no active authenticated account for '$HostName'. Run: gh auth login --hostname $HostName"
    }

    $account = $active[0]
    if ([string]$account.state -ne 'success') {
        throw "the active gh account '$($account.login)' for '$HostName' is not authenticated."
    }

    $auth = [pscustomobject]@{
        Host   = $HostName
        Login  = [string]$account.login
        Scopes = [string]$account.scopes
        State  = [string]$account.state
    }
    $script:ActionWorkflowAuthCache[$cacheKey] = $auth
    return $auth
}

function Get-ActionWorkflowContext {
    $context = Get-ActionWorkflowRepositoryContext
    $auth = Assert-ActionWorkflowGhAuthenticated $context.Host
    $context | Add-Member -NotePropertyName GhLogin -NotePropertyValue $auth.Login
    $context | Add-Member -NotePropertyName GhScopes -NotePropertyValue $auth.Scopes
    return $context
}

function Get-ActionWorkflowLocalWorkflowFiles {
    param([Parameter(Mandatory = $true)]$Context)

    $workflowDirectory = Join-Path (Join-Path $Context.RepoRoot '.github') 'workflows'
    if (-not (Test-Path -LiteralPath $workflowDirectory)) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $workflowDirectory -PathType Container)) {
        throw "the workflow path is not a directory: $workflowDirectory"
    }

    $files = @(Get-ChildItem -LiteralPath $workflowDirectory -File -ErrorAction Stop |
        Where-Object { $_.Extension -in @('.yml', '.yaml') } |
        Sort-Object Name)

    $workflows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $files) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        $name = $file.BaseName
        $nameMatch = [regex]::Match($content, '(?m)^\s*name\s*:\s*(?<name>[^#\r\n]+?)\s*$')
        if ($nameMatch.Success) {
            $candidate = $nameMatch.Groups['name'].Value.Trim()
            if (($candidate.StartsWith("'") -and $candidate.EndsWith("'")) -or
                ($candidate.StartsWith('"') -and $candidate.EndsWith('"'))) {
                $candidate = $candidate.Substring(1, $candidate.Length - 2)
            }
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $name = $candidate
            }
        }

        $workflows.Add([pscustomobject]@{
            Name     = $name
            Path     = ".github/workflows/$($file.Name)"
            FileName = $file.Name
            FullPath = $file.FullName
            Content  = $content
        })
    }

    return [object[]]$workflows.ToArray()
}

function Test-ActionWorkflowLocalWorkflow {
    param([Parameter(Mandatory = $true)]$Workflow)

    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace([string]$Workflow.Content)) {
        $errors.Add('file is empty.')
        return [object[]]$errors.ToArray()
    }

    if ($Workflow.Content -notmatch '(?m)^\s*(?:on|"on"|''on'')\s*:') {
        $errors.Add('missing top-level on: trigger.')
    }
    if ($Workflow.Content -notmatch '(?m)^\s*(?:jobs|"jobs"|''jobs'')\s*:') {
        $errors.Add('missing top-level jobs: section.')
    }
    else {
        $jobCount = 0
        $lines = $Workflow.Content -split "\r?\n"
        $inJobs = $false
        foreach ($line in $lines) {
            if (-not $inJobs) {
                if ($line -match '^\s*(?:jobs|"jobs"|''jobs'')\s*:\s*(?:#.*)?$') {
                    $inJobs = $true
                }
                continue
            }
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
                continue
            }
            if ($line -match '^\s{2,}(?<job>[A-Za-z0-9_.-]+)\s*:') {
                $jobCount++
                continue
            }
            if ($line -match '^\S') {
                break
            }
        }
        if ($jobCount -eq 0) {
            $errors.Add('jobs: section does not define any jobs.')
        }
    }

    return [object[]]$errors.ToArray()
}

function Get-ActionWorkflowList {
    param([Parameter(Mandatory = $true)]$Context)

    $result = Invoke-ActionWorkflowGh @(
        'workflow', 'list',
        '--all',
        '--limit', '100',
        '--json', 'id,name,path,state',
        '--repo', $Context.RepoSpec
    )
    $payload = ConvertFrom-ActionWorkflowGhJson $result "workflow discovery for '$($Context.FullName)'"
    return [object[]]@($payload | Where-Object { $null -ne $_ } | Sort-Object name, path)
}

function Find-ActionWorkflowMatchesFromList {
    param(
        [object[]]$Workflows,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $value = $Selector.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'the workflow selector is empty.'
    }

    $availableWorkflows = @($Workflows | Where-Object { $null -ne $_ })
    if ($value -match '^[0-9]+$') {
        return [object[]]@($availableWorkflows | Where-Object { [string]$_.id -eq $value })
    }

    $normalized = $value.Replace('\', '/').TrimStart('.', '/')
    $byPath = @($availableWorkflows | Where-Object {
        ([string]$_.path).Replace('\', '/').TrimStart('.', '/') -ieq $normalized
    })
    if ($byPath.Count -gt 0) {
        return [object[]]$byPath
    }

    $byFile = @($availableWorkflows | Where-Object {
        [System.IO.Path]::GetFileName(([string]$_.path).Replace('\', '/')) -ieq $value
    })
    if ($byFile.Count -gt 0) {
        return [object[]]$byFile
    }

    return [object[]]@($availableWorkflows | Where-Object { [string]$_.name -ieq $value })
}

function Resolve-ActionWorkflowFromList {
    param(
        [object[]]$Workflows,
        [Parameter(Mandatory = $true)][string]$Selector,
        [string]$RepositoryName = 'the repository'
    )

    $availableWorkflows = @($Workflows | Where-Object { $null -ne $_ })
    if ($availableWorkflows.Count -eq 0) {
        throw "no GitHub Actions workflows were found for '$RepositoryName'."
    }

    $matches = @(Find-ActionWorkflowMatchesFromList $availableWorkflows $Selector)
    if ($matches.Count -eq 0) {
        $available = @($availableWorkflows | ForEach-Object { "$($_.name) [$($_.path)]" }) -join '; '
        throw "workflow '$Selector' was not found for '$RepositoryName'. Available workflows: $available"
    }
    if ($matches.Count -gt 1) {
        $available = @($matches | ForEach-Object { "id $($_.id): $($_.name) [$($_.path)]" }) -join '; '
        throw "workflow selector '$Selector' is ambiguous. Matches: $available"
    }

    return $matches[0]
}

function Resolve-ActionWorkflow {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $workflows = @(Get-ActionWorkflowList $Context)
    if ($workflows.Count -eq 0) {
        throw "no GitHub Actions workflows were found for '$($Context.FullName)'."
    }
    return Resolve-ActionWorkflowFromList -Workflows $workflows -Selector $Selector -RepositoryName $Context.FullName
}

function Get-ActionWorkflowRuns {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Workflow,
        [string]$Branch,
        [switch]$AllBranches,
        [int]$Limit = 10
    )

    if ($AllBranches -and -not [string]::IsNullOrWhiteSpace($Branch)) {
        throw 'choose either a branch or all branches, not both.'
    }
    if ($Limit -lt 1 -or $Limit -gt 100) {
        throw 'the run limit must be between 1 and 100.'
    }

    $arguments = @(
        'run', 'list',
        '--repo', $Context.RepoSpec,
        '--limit', [string]$Limit,
        '--json', 'attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,status,url,workflowDatabaseId,workflowName'
    )

    if ($null -ne $Workflow) {
        $arguments += @('--workflow', [string]$Workflow.path, '--all')
    }
    if (-not $AllBranches -and -not [string]::IsNullOrWhiteSpace($Branch)) {
        $arguments += @('--branch', $Branch)
    }

    $result = Invoke-ActionWorkflowGh $arguments
    $payload = ConvertFrom-ActionWorkflowGhJson $result "workflow run discovery for '$($Context.FullName)'"
    return [object[]]@($payload | Where-Object { $null -ne $_ })
}

function Get-ActionWorkflowRun {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ($RunId -notmatch '^[0-9]+$') {
        throw "workflow run id '$RunId' is not valid."
    }

    $result = Invoke-ActionWorkflowGh @(
        'run', 'view', $RunId,
        '--repo', $Context.RepoSpec,
        '--json', 'attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,status,url,workflowDatabaseId,workflowName'
    )
    if ($result.ExitCode -ne 0) {
        throw "workflow run '$RunId' was not found or is not accessible for '$($Context.FullName)'.`n$(Format-ActionWorkflowFailure $result)"
    }

    $run = ConvertFrom-ActionWorkflowGhJson $result "workflow run '$RunId' lookup"
    if ($null -eq $run -or [string]$run.databaseId -ne $RunId) {
        throw "workflow run '$RunId' could not be verified for '$($Context.FullName)'."
    }

    return $run
}

function Get-ActionWorkflowJobs {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run
    )

    $result = Invoke-ActionWorkflowGh @(
        'run', 'view', [string]$Run.databaseId,
        '--repo', $Context.RepoSpec,
        '--json', 'jobs'
    )
    $payload = ConvertFrom-ActionWorkflowGhJson $result "job discovery for run '$($Run.databaseId)'"
    if ($null -eq $payload) {
        return @()
    }
    return [object[]]@($payload.jobs | Where-Object { $null -ne $_ })
}

function Resolve-ActionWorkflowJob {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    if ($JobId -notmatch '^[0-9]+$') {
        throw "job id '$JobId' is not valid."
    }

    $jobs = @(Get-ActionWorkflowJobs $Context $Run)
    $job = @($jobs | Where-Object { [string]$_.databaseId -eq $JobId }) | Select-Object -First 1
    if ($null -eq $job) {
        throw "job '$JobId' does not belong to workflow run '$($Run.databaseId)'."
    }
    return $job
}

function Test-ActionWorkflowRunMatchesWorkflow {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Workflow
    )

    if ($null -ne $Run.workflowDatabaseId -and -not [string]::IsNullOrWhiteSpace([string]$Run.workflowDatabaseId)) {
        return ([string]$Run.workflowDatabaseId -eq [string]$Workflow.id)
    }
    return ([string]$Run.workflowName -ieq [string]$Workflow.name)
}

function Resolve-ActionWorkflowRun {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$RunId,
        [string]$WorkflowSelector,
        [string]$Branch,
        [switch]$AllBranches
    )

    $workflow = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkflowSelector)) {
        $workflow = Resolve-ActionWorkflow $Context $WorkflowSelector
    }

    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $run = Get-ActionWorkflowRun $Context $RunId
        if ($null -ne $workflow -and -not (Test-ActionWorkflowRunMatchesWorkflow $run $workflow)) {
            throw "workflow run '$RunId' belongs to '$($run.workflowName)', not workflow '$($workflow.name)'."
        }
        if (-not $AllBranches -and -not [string]::IsNullOrWhiteSpace($Branch) -and $run.headBranch -cne $Branch) {
            throw "workflow run '$RunId' is for branch '$($run.headBranch)', not '$Branch'."
        }
        return $run
    }

    $runs = @(Get-ActionWorkflowRuns -Context $Context -Workflow $workflow -Branch $Branch -AllBranches:$AllBranches -Limit 1)
    if ($runs.Count -eq 0) {
        $scope = if ($null -ne $workflow) { "workflow '$($workflow.name)'" } else { 'the selected filters' }
        throw "no workflow runs were found for $scope."
    }

    $run = Get-ActionWorkflowRun $Context ([string]$runs[0].databaseId)
    if ($null -ne $workflow -and -not (Test-ActionWorkflowRunMatchesWorkflow $run $workflow)) {
        throw "the latest workflow run did not match workflow '$($workflow.name)'."
    }
    if (-not $AllBranches -and -not [string]::IsNullOrWhiteSpace($Branch) -and $run.headBranch -cne $Branch) {
        throw "the latest workflow run is for branch '$($run.headBranch)', not '$Branch'."
    }
    return $run
}

function ConvertTo-ActionWorkflowOptions {
    param(
        [string[]]$Arguments,
        [hashtable]$ValueOptions,
        [hashtable]$SwitchOptions
    )

    $result = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = [string]$Arguments[$i]
        if (-not $argument.StartsWith('--')) {
            throw "unexpected argument '$argument'."
        }

        $name = $argument
        $inlineValue = $null
        $equalsIndex = $argument.IndexOf('=')
        if ($equalsIndex -ge 0) {
            $name = $argument.Substring(0, $equalsIndex)
            $inlineValue = $argument.Substring($equalsIndex + 1)
        }

        if ($ValueOptions.ContainsKey($name)) {
            $key = $ValueOptions[$name]
            if ($result.ContainsKey($key)) {
                throw "option '$name' was specified more than once."
            }
            if ($null -eq $inlineValue) {
                if ($i + 1 -ge $Arguments.Count) {
                    throw "option '$name' requires a value."
                }
                $i++
                $inlineValue = [string]$Arguments[$i]
            }
            if ([string]::IsNullOrWhiteSpace($inlineValue)) {
                throw "option '$name' requires a non-empty value."
            }
            $result[$key] = $inlineValue
            continue
        }

        if ($SwitchOptions.ContainsKey($name)) {
            $key = $SwitchOptions[$name]
            if ($result.ContainsKey($key)) {
                throw "option '$name' was specified more than once."
            }
            if ($null -ne $inlineValue) {
                throw "option '$name' does not take a value."
            }
            $result[$key] = $true
            continue
        }

        throw "unknown option '$name'."
    }

    return $result
}

function ConvertTo-ActionWorkflowPositiveInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Minimum = 1,
        [int]$Maximum = 2147483647
    )

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum."
    }
    return $parsed
}

function ConvertTo-ActionWorkflowBranchFilter {
    param(
        [string]$Branch,
        [switch]$AllBranches
    )

    if ($AllBranches -and -not [string]::IsNullOrWhiteSpace($Branch)) {
        throw 'choose either --branch or --all-branches, not both.'
    }
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch.StartsWith('-')) {
        throw 'the branch name cannot start with a dash.'
    }
    return $Branch
}

function Format-ActionWorkflowStatusLabel {
    param($Run)

    $status = [string]$Run.status
    $conclusion = [string]$Run.conclusion
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'unknown'
    }
    if ([string]::IsNullOrWhiteSpace($conclusion)) {
        return $status
    }
    return "$status/$conclusion"
}

function Write-ActionWorkflowRunDetails {
    param([Parameter(Mandatory = $true)]$Run)

    Write-Output "Run:         $($Run.databaseId)"
    Write-Output "Workflow:    $($Run.workflowName)"
    Write-Output "Branch:      $($Run.headBranch)"
    Write-Output "Status:      $(Format-ActionWorkflowStatusLabel $Run)"
    Write-Output "Event:       $($Run.event)"
    if (-not [string]::IsNullOrWhiteSpace([string]$Run.displayTitle)) {
        Write-Output "Title:       $($Run.displayTitle)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Run.createdAt)) {
        Write-Output "Created:     $($Run.createdAt)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Run.url)) {
        Write-Output "URL:         $($Run.url)"
    }
}

function Get-ActionWorkflowRunExitCode {
    param([Parameter(Mandatory = $true)]$Run)

    $conclusion = [string]$Run.conclusion
    if ($conclusion -in @('success', 'neutral', 'skipped')) {
        return 0
    }
    return 1
}

function Format-ActionWorkflowColumn {
    param(
        [string]$Value,
        [int]$Width
    )

    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) {
        $text = '-'
    }
    if ($text.Length -gt $Width) {
        if ($Width -le 1) {
            return $text.Substring(0, $Width)
        }
        return $text.Substring(0, $Width - 1) + '~'
    }
    return $text.PadRight($Width)
}

function New-ActionWorkflowTemplate {
    param([Parameter(Mandatory = $true)][string]$Name)

    $lines = @(
        "name: '$Name'",
        '',
        'on: [push, workflow_dispatch]',
        '',
        'permissions:',
        '  contents: read',
        '',
        'jobs:',
        '  smoke:',
        '    name: Smoke check',
        '    runs-on: ubuntu-latest',
        '    timeout-minutes: 5',
        '    steps:',
        '      - name: Check out repository',
        '        uses: actions/checkout@v4',
        '      - name: Confirm workflow execution',
        '        run: echo "Workflow is running for ${{ github.repository }}."'
    )
    return (($lines -join "`n") + "`n")
}
