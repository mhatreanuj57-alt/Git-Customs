function Show-GitDoctorUsage {
    Write-Output 'Usage: git doctor [--no-github] [--strict]'
    Write-Output ''
    Write-Output 'Runs read-only diagnostics for a repository, local GitHub Actions workflows,'
    Write-Output 'and optional GitHub CLI access. The command never changes files, refs, or remotes.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --no-github  Skip GitHub CLI authentication and repository access checks'
    Write-Output '  --strict     Exit non-zero when warnings are found'
    Write-Output ''
    Write-Output 'Exit codes: 0 for pass/warnings, 1 for failures or warnings with --strict.'
}

function New-GitDoctorResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = ''
    )

    [pscustomobject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }
}

function Write-GitDoctorResults {
    param([Parameter(Mandatory = $true)]$Results)

    foreach ($result in @($Results)) {
        Write-Output ('{0,-5} {1,-28} {2}' -f $result.Status, $result.Name, $result.Detail)
    }
}

function Invoke-GitDoctor {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitDoctorUsage
        return
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{} `
        -SwitchOptions @{ '--no-github' = 'NoGitHub'; '--strict' = 'Strict' }
    $skipGitHub = $options.ContainsKey('NoGitHub')
    $strict = $options.ContainsKey('Strict')

    $results = New-Object 'System.Collections.Generic.List[object]'

    $gitVersion = Invoke-GitCommand -Arguments @('--version') -AllowFailure
    if ($gitVersion.ExitCode -eq 0) {
        $results.Add((New-GitDoctorResult 'Git' 'PASS' $gitVersion.Text.Trim()))
    }
    else {
        $results.Add((New-GitDoctorResult 'Git' 'FAIL' 'git is not available on PATH.'))
        foreach ($result in $results) { Write-GitDoctorResults ([object[]]@($result)) }
        Write-Output ''
        Write-Output 'Doctor found 1 failure.'
        $script:ExitCode = 1
        return
    }

    $root = Get-GitCommandRepoRoot -AllowMissing
    if ([string]::IsNullOrWhiteSpace($root)) {
        $results.Add((New-GitDoctorResult 'Repository' 'FAIL' 'not inside a Git working tree.'))
        Write-GitDoctorResults ([object[]]$results.ToArray())
        Write-Output ''
        Write-Output 'Doctor found 1 failure.'
        $script:ExitCode = 1
        return
    }

    $info = Get-GitCommandRepoInfo -RepoRoot $root
    $results.Add((New-GitDoctorResult 'Repository' 'PASS' $root))

    if ($info.Detached) {
        $results.Add((New-GitDoctorResult 'Branch' 'WARN' 'detached HEAD; check out a branch before changing or publishing.'))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($info.Branch)) {
        $results.Add((New-GitDoctorResult 'Branch' 'PASS' "$($info.Branch) at $(Format-GitCommandShortSha $info.Head)"))
    }
    else {
        $results.Add((New-GitDoctorResult 'Branch' 'WARN' 'no current branch.'))
    }

    if (-not $info.HasHead) {
        $results.Add((New-GitDoctorResult 'History' 'WARN' 'repository has no commits.'))
    }
    else {
        $results.Add((New-GitDoctorResult 'History' 'PASS' "HEAD is $(Format-GitCommandShortSha $info.Head)."))
    }

    if ($info.ChangedPaths.Count -eq 0) {
        $results.Add((New-GitDoctorResult 'Worktree' 'PASS' 'clean.'))
    }
    else {
        $sample = @($info.ChangedPaths | Select-Object -First 5) -join ', '
        $results.Add((New-GitDoctorResult 'Worktree' 'WARN' "$($info.ChangedPaths.Count) changed path(s): $sample"))
    }

    $conflicts = Invoke-GitCommand -RepoRoot $root -Arguments @('diff', '--name-only', '--diff-filter=U') -AllowFailure
    $conflictPaths = @($conflicts.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($conflictPaths.Count -eq 0) {
        $results.Add((New-GitDoctorResult 'Conflicts' 'PASS' 'no unresolved merge conflicts.'))
    }
    else {
        $results.Add((New-GitDoctorResult 'Conflicts' 'FAIL' "$($conflictPaths.Count) unresolved conflict(s): $($conflictPaths -join ', ')"))
    }

    $remote = $null
    if (-not $info.HasOrigin) {
        $results.Add((New-GitDoctorResult 'Origin' 'WARN' 'no origin remote configured; GitHub commands are unavailable.'))
    }
    else {
        try {
            $remote = ConvertTo-ActionWorkflowGitHubRemoteInfo $info.OriginUrl
            $results.Add((New-GitDoctorResult 'Origin' 'PASS' "$($remote.FullName) ($($remote.Host))"))
        }
        catch {
            $results.Add((New-GitDoctorResult 'Origin' 'WARN' "origin is not a supported GitHub remote: $($info.OriginUrl)"))
        }
    }

    if ($info.Detached -or -not $info.HasHead) {
        $results.Add((New-GitDoctorResult 'Upstream' 'SKIP' 'no branch to compare with a remote.'))
    }
    elseif (-not $info.HasUpstream) {
        $results.Add((New-GitDoctorResult 'Upstream' 'WARN' 'current branch has no upstream; push with -u before PR/release operations.'))
    }
    elseif ($info.Ahead -eq 0 -and $info.Behind -eq 0) {
        $results.Add((New-GitDoctorResult 'Upstream' 'PASS' "$($info.Upstream) is in sync."))
    }
    else {
        $results.Add((New-GitDoctorResult 'Upstream' 'WARN' "$($info.Upstream): $($info.Ahead) ahead, $($info.Behind) behind."))
    }

    $defaultBranch = $info.DefaultBranch
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        $defaultBranch = Get-GitCommandDefaultBranch -RepoRoot $root
    }
    if ($info.Detached) {
        $results.Add((New-GitDoctorResult 'Default branch' 'SKIP' "default branch is '$defaultBranch'."))
    }
    elseif ($info.Branch -ieq $defaultBranch) {
        $results.Add((New-GitDoctorResult 'Default branch' 'PASS' "on '$defaultBranch'."))
    }
    else {
        $results.Add((New-GitDoctorResult 'Default branch' 'WARN' "on '$($info.Branch)'; default is '$defaultBranch'."))
    }

    $workflowDirectory = Join-Path (Join-Path $root '.github') 'workflows'
    $workflowFiles = @()
    if (Test-Path -LiteralPath $workflowDirectory -PathType Container) {
        $workflowFiles = @(Get-ChildItem -LiteralPath $workflowDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.yml', '.yaml') } |
            Sort-Object Name)
    }
    if ($workflowFiles.Count -eq 0) {
        $results.Add((New-GitDoctorResult 'Workflows' 'WARN' 'no workflow files in .github/workflows.'))
    }
    else {
        $workflowErrors = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in $workflowFiles) {
            $content = [System.IO.File]::ReadAllText($file.FullName)
            $workflow = [pscustomobject]@{
                Name     = $file.BaseName
                Path     = ".github/workflows/$($file.Name)"
                FileName = $file.Name
                FullPath = $file.FullName
                Content  = $content
            }
            $errors = @(Test-ActionWorkflowLocalWorkflow $workflow)
            foreach ($errorText in $errors) {
                $workflowErrors.Add("$($file.Name): $errorText")
            }
        }
        if ($workflowErrors.Count -eq 0) {
            $results.Add((New-GitDoctorResult 'Workflows' 'PASS' "$($workflowFiles.Count) local workflow file(s) valid."))
        }
        else {
            $results.Add((New-GitDoctorResult 'Workflows' 'FAIL' ($workflowErrors -join '; ')))
        }
    }

    $worktrees = @(Get-GitCommandWorktrees $root)
    $stale = @($worktrees | Where-Object { $_.Prunable -or -not $_.Exists })
    if ($stale.Count -gt 0) {
        $results.Add((New-GitDoctorResult 'Worktrees' 'WARN' "$($stale.Count) stale or missing worktree(s); run 'git work prune'."))
    }
    else {
        $results.Add((New-GitDoctorResult 'Worktrees' 'PASS' "$($worktrees.Count) registered worktree(s)."))
    }

    if ($skipGitHub) {
        $results.Add((New-GitDoctorResult 'GitHub CLI' 'SKIP' 'skipped by --no-github.'))
        $results.Add((New-GitDoctorResult 'GitHub access' 'SKIP' 'skipped by --no-github.'))
    }
    else {
        $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $ghCommand) {
            $results.Add((New-GitDoctorResult 'GitHub CLI' 'WARN' 'gh is not installed or is not available on PATH.'))
            $results.Add((New-GitDoctorResult 'GitHub access' 'SKIP' 'gh is unavailable.'))
        }
        else {
            $auth = Invoke-GitCommandGh -Arguments @('auth', 'status', '--json', 'hosts', '--hostname', 'github.com') -AllowFailure
            if ($auth.ExitCode -eq 0) {
                $results.Add((New-GitDoctorResult 'GitHub CLI' 'PASS' 'gh is authenticated for github.com.'))
            }
            else {
                $results.Add((New-GitDoctorResult 'GitHub CLI' 'WARN' 'gh is not authenticated for github.com; run gh auth login.'))
            }

            if ($null -ne $remote -and $auth.ExitCode -eq 0) {
                $repoView = Invoke-GitCommandGh -Arguments @('repo', 'view', $remote.RepoSpec, '--json', 'nameWithOwner,defaultBranchRef') -AllowFailure
                if ($repoView.ExitCode -eq 0) {
                    $results.Add((New-GitDoctorResult 'GitHub access' 'PASS' "repository $($remote.RepoSpec) is reachable."))
                }
                else {
                    $results.Add((New-GitDoctorResult 'GitHub access' 'WARN' 'could not verify GitHub repository access.'))
                }
            }
            else {
                $results.Add((New-GitDoctorResult 'GitHub access' 'SKIP' 'no supported GitHub origin to verify.'))
            }
        }
    }

    $passed = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
    $warnings = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
    $failures = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count

    Write-GitDoctorResults ([object[]]$results.ToArray())
    Write-Output ''
    Write-Output "Summary: $passed passed, $warnings warning(s), $failures failure(s), $skipped skipped."

    if ($failures -gt 0 -or ($strict -and $warnings -gt 0)) {
        Write-Output 'Doctor found issues that require attention.'
        $script:ExitCode = 1
        return
    }
    Write-Output 'Doctor checks passed.'
    $script:ExitCode = 0
}
