[CmdletBinding()]
param([switch]$Keep)

. (Join-Path $PSScriptRoot 'lib\TestHelpers.ps1')
Initialize-TestEnvironment -TestScriptRoot $PSScriptRoot -Suite 'doctor' -Keep:$Keep

function Set-TestWorkflow {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$Name = 'ci.yml'
    )
    $directory = Join-Path (Join-Path $Repo '.github') 'workflows'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory $Name), $Content)
}

function New-DoctorRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$NoWorkflow,
        [switch]$NoWorkflowCommit
    )
    $repo = New-TestRepo -Path (Join-Path $script:SuiteRoot $Name)
    if (-not $NoWorkflow) {
        Set-TestWorkflow -Repo $repo -Content @'
name: CI
on:
  push:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
'@
        Invoke-SetupGit $repo @('add', '.github/workflows/ci.yml') | Out-Null
        if (-not $NoWorkflowCommit) {
            Invoke-SetupGit $repo @('commit', '-m', 'add workflow') | Out-Null
        }
    }
    $head = (& git -C $repo rev-parse HEAD).Trim()
    Set-OriginTracking -Repo $repo -Branch 'main' -Sha $head
    Invoke-SetupGit $repo @('branch', '--set-upstream-to', 'origin/main', 'main') | Out-Null
    New-TestState -Name $Name | Out-Null
    return $repo
}

try {
    Test-Case 'doctor help is available' {
        $repo = New-DoctorRepo -Name 'help'
        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor', '-h')
        Assert-ExitCode $result 0 'doctor -h'
        Assert-Match $result.Text 'Usage: git doctor' 'help output'
        Assert-Match $result.Text '--no-github' 'help options'
    }

    Test-Case 'doctor passes a clean repository with a valid workflow' {
        $repo = New-DoctorRepo -Name 'clean'
        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github')
        Assert-ExitCode $result 0 'clean doctor'
        Assert-Match $result.Text 'PASS  Workflows\s+1 local workflow file\(s\) valid' 'workflow pass'
        Assert-Match $result.Text 'PASS  Upstream' 'upstream pass'
        Assert-Match $result.Text 'SKIP  GitHub CLI' 'github skipped'
        Assert-Match $result.Text '0 failure\(s\)' 'no failures'
        Assert-Match $result.Text 'Doctor checks passed' 'doctor verdict'
    }

    Test-Case 'doctor passes GitHub CLI and repository access with fake gh' {
        $repo = New-DoctorRepo -Name 'github'
        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor')
        Assert-ExitCode $result 0 'github doctor'
        Assert-Match $result.Text 'PASS  GitHub CLI\s+gh is authenticated' 'auth pass'
        Assert-Match $result.Text 'PASS  GitHub access\s+repository example/demo is reachable' 'repo access pass'
        Assert-Match $result.Text 'Doctor checks passed' 'doctor verdict'
    }

    Test-Case 'doctor reports dirty worktrees without failing unless strict' {
        $repo = New-DoctorRepo -Name 'dirty'
        Add-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'working change'
        $normal = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github')
        Assert-ExitCode $normal 0 'dirty doctor'
        Assert-Match $normal.Text 'WARN  Worktree\s+1 changed path' 'dirty warning'

        $strict = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github', '--strict')
        Assert-ExitCode $strict 1 'strict dirty doctor'
        Assert-Match $strict.Text 'Doctor found issues that require attention' 'strict verdict'
    }

    Test-Case 'doctor warns when workflows are missing' {
        $repo = New-DoctorRepo -Name 'no-workflows' -NoWorkflow
        $normal = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github')
        Assert-ExitCode $normal 0 'missing workflow doctor'
        Assert-Match $normal.Text 'WARN  Workflows\s+no workflow files' 'missing workflow warning'

        $strict = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github', '--strict')
        Assert-ExitCode $strict 1 'missing workflow strict'
    }

    Test-Case 'doctor fails for an invalid local workflow' {
        $repo = New-DoctorRepo -Name 'invalid-workflow' -NoWorkflow
        Set-TestWorkflow -Repo $repo -Content "name: Broken`n"
        Invoke-SetupGit $repo @('add', '.github/workflows/ci.yml') | Out-Null
        Invoke-SetupGit $repo @('commit', '-m', 'add broken workflow') | Out-Null

        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github')
        Assert-ExitCode $result 1 'invalid workflow doctor'
        Assert-Match $result.Text 'FAIL  Workflows' 'invalid workflow failure'
        Assert-Match $result.Text 'missing top-level on' 'missing on detail'
        Assert-Match $result.Text '1 failure\(s\)' 'failure count'
    }

    Test-Case 'doctor warns when GitHub authentication fails' {
        $repo = New-DoctorRepo -Name 'auth-fail'
        Set-StateFailure @('auth')
        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--strict')
        Assert-ExitCode $result 1 'auth failure strict'
        Assert-Match $result.Text 'WARN  GitHub CLI\s+gh is not authenticated' 'auth warning'
        Assert-Match $result.Text 'SKIP  GitHub access' 'access skipped after auth failure'
    }

    Test-Case 'doctor warns when repository access cannot be verified' {
        $repo = New-DoctorRepo -Name 'repo-fail'
        Set-StateFailure @('repo-view')
        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor')
        Assert-ExitCode $result 0 'repo view failure'
        Assert-Match $result.Text 'WARN  GitHub access\s+could not verify' 'access warning'
    }

    Test-Case 'doctor fails outside a Git repository' {
        $directory = New-TestDirectory 'not-a-repo'
        $result = Invoke-TestGit -Repo $directory -Arguments @('doctor', '--no-github')
        Assert-ExitCode $result 1 'outside repository'
        Assert-Match $result.Text 'FAIL  Repository\s+not inside a Git working tree' 'repository failure'
        Assert-Match $result.Text 'Doctor found 1 failure' 'failure count'
    }

    Test-Case 'doctor warns about stale worktree metadata' {
        $repo = New-DoctorRepo -Name 'stale-worktree'
        $path = Join-Path $script:SuiteRoot 'stale-wt'
        $added = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/stale', '--path', $path)
        Assert-ExitCode $added 0 'add stale worktree'
        Remove-Item -LiteralPath $path -Recurse -Force

        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github')
        Assert-ExitCode $result 0 'stale worktree doctor'
        Assert-Match $result.Text 'WARN  Worktrees\s+1 stale or missing' 'stale worktree warning'
    }

    Test-Case 'doctor warns for detached HEAD with --strict failure' {
        $repo = New-DoctorRepo -Name 'detached'
        $sha = (& git -C $repo rev-parse HEAD).Trim()
        Invoke-SetupGit $repo @('checkout', '--detach', $sha) | Out-Null
        $normal = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github')
        Assert-ExitCode $normal 0 'detached doctor'
        Assert-Match $normal.Text 'WARN  Branch\s+detached HEAD' 'detached warning'
        Assert-Match $normal.Text 'SKIP  Upstream' 'detached upstream skip'

        $strict = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--no-github', '--strict')
        Assert-ExitCode $strict 1 'detached strict'
    }

    Test-Case 'doctor rejects unknown options' {
        $repo = New-DoctorRepo -Name 'unknown-option'
        $result = Invoke-TestGit -Repo $repo -Arguments @('doctor', '--bogus')
        Assert-ExitCode $result 1 'unknown doctor option'
        Assert-Match $result.Error 'unknown option' 'unknown option error'
    }
}
finally {
    Complete-TestEnvironment
}
