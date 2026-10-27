$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-e2e-tests'
if ($env:GIT_CUSTOMS_TEST_BIN) {
    $sourceDir = $env:GIT_CUSTOMS_TEST_BIN
}
else {
    $sourceDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts'
}
$fakeGhDir = Join-Path $PSScriptRoot 'fake-gh'
$statePath = Join-Path $testRoot 'fake-gh-state.json'
$logPath = Join-Path $testRoot 'fake-gh-calls.log'
$repoPath = Join-Path $testRoot 'repo'

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$script:OriginalPath = $env:Path
$script:OriginalLocation = Get-Location

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Output "PASS $Name"
    }
    else {
        $script:Failed++
        $script:Failures.Add($Name)
        Write-Output "FAIL $Name"
    }
}

function Set-FakeState {
    param([hashtable]$State)
    [System.IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
}

function Get-FakeState {
    return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}

function New-Job {
    param([string]$Id, [string]$Name, [string]$Conclusion)
    [ordered]@{
        databaseId = [long]$Id
        name = $Name
        status = 'completed'
        conclusion = $Conclusion
        log = "log $Id"
        failedLog = "failed log $Id"
    }
}

function New-Run {
    param(
        [string]$Id,
        [string]$WorkflowName,
        [string]$WorkflowPath,
        [string]$WorkflowId,
        [string]$Branch,
        [string]$Status,
        [string]$Conclusion,
        [string]$CreatedAt,
        [string]$Title,
        [object[]]$Jobs
    )
    [ordered]@{
        databaseId = [long]$Id
        workflowName = $WorkflowName
        workflowPath = $WorkflowPath
        workflowDatabaseId = [long]$WorkflowId
        headBranch = $Branch
        status = $Status
        conclusion = $Conclusion
        createdAt = $CreatedAt
        displayTitle = $Title
        event = 'push'
        attempt = 1
        headSha = 'abc123'
        url = "https://github.com/example/demo/actions/runs/$Id"
        jobs = @($Jobs)
    }
}

function Invoke-Cli {
    param([string[]]$Arguments)

    Push-Location -LiteralPath $repoPath
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:Path = "$fakeGhDir;$sourceDir;$script:OriginalPath"
        $output = & git action-workflow @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $exitCode
            Text     = (@($output | ForEach-Object { [string]$_ }) -join "`n")
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
        Pop-Location
        $env:Path = $script:OriginalPath
    }
}

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
    git -C $repoPath init -b main | Out-Null
    git -C $repoPath config user.email 'tester@example.com'
    git -C $repoPath config user.name 'Tester'
    Set-Content -LiteralPath (Join-Path $repoPath 'README.md') -Value 'test' -Encoding ASCII
    git -C $repoPath add README.md
    git -C $repoPath commit -m 'Initial commit' | Out-Null
    git -C $repoPath remote add origin 'https://github.com/example/demo.git'
    $env:FAKE_GH_STATE = $statePath
    $env:FAKE_GH_LOG = $logPath

    Set-FakeState @{ workflows = @(); runs = @(); failures = @{}; rerunCalls = @() }

    $init = Invoke-Cli @('init')
    $workflowPath = Join-Path $repoPath '.github\workflows\action-workflow.yml'
    Assert-True ($init.ExitCode -eq 0 -and (Test-Path -LiteralPath $workflowPath) -and $init.Text -match 'Created: .github/workflows/action-workflow.yml') 'end-to-end init creates the starter workflow'

    $localOnly = Invoke-Cli @('validate')
    Assert-True ($localOnly.ExitCode -eq 0 -and $localOnly.Text -match 'local only' -and $localOnly.Text -match 'not registered on GitHub yet') 'end-to-end validate reports an unregistered local workflow'

    $workflows = @(
        @{ id = 101; name = 'Action Workflow'; path = '.github/workflows/action-workflow.yml'; state = 'active' },
        @{ id = 102; name = 'Build Check'; path = '.github/workflows/ci.yml'; state = 'active' }
    )
    $runs = @(
        (New-Run '7001' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'completed' 'success' '2026-10-27T10:00:00Z' 'Main success' @(
            (New-Job '7101' 'build' 'success')
        )),
        (New-Run '7002' 'Build Check' '.github/workflows/ci.yml' '102' 'feature' 'completed' 'failure' '2026-10-27T11:00:00Z' 'Feature failure' @(
            (New-Job '7102' 'test' 'failure'),
            (New-Job '7103' 'deploy' 'success')
        ))
    )
    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }

    $strict = Invoke-Cli @('validate', '--workflow', 'action-workflow.yml', '--require-remote')
    Assert-True ($strict.ExitCode -eq 0 -and $strict.Text -match 'registered \(active\)' -and $strict.Text -match 'no warnings') 'end-to-end strict validation accepts a registered workflow'

    $status = Invoke-Cli @('status', '--all-branches')
    Assert-True ($status.ExitCode -eq 0 -and $status.Text -match '7001' -and $status.Text -match '7002' -and $status.Text -match 'completed/success' -and $status.Text -match 'completed/failure') 'end-to-end status lists runs across branches'

    $filteredStatus = Invoke-Cli @('status', '--workflow', 'ci.yml', '--branch', 'feature')
    Assert-True ($filteredStatus.ExitCode -eq 0 -and $filteredStatus.Text -match '7002' -and $filteredStatus.Text -notmatch '7001' -and $filteredStatus.Text -match 'Build Check') 'end-to-end status filters by workflow and branch'

    $watch = Invoke-Cli @('watch', '--run', '7001')
    Assert-True ($watch.ExitCode -eq 0 -and $watch.Text -match 'Run 7001 is already completed: completed/success') 'end-to-end watch returns a successful completed run'

    $logs = Invoke-Cli @('logs', '--run', '7002', '--job', '7102', '--failed')
    Assert-True ($logs.ExitCode -eq 0 -and $logs.Text -match 'Job:\s+7102 \(test\)' -and $logs.Text -match 'failed log 7102') 'end-to-end logs retrieves failed job output'

    $retry = Invoke-Cli @('retry', '--run', '7002', '--yes')
    $state = Get-FakeState
    $rerunCalls = @($state.rerunCalls)
    Assert-True ($retry.ExitCode -eq 0 -and $retry.Text -match 'Requested failed jobs re-run' -and $rerunCalls.Count -eq 1 -and $rerunCalls[0].RunId -eq '7002' -and $rerunCalls[0].Mode -eq 'failed') 'end-to-end retry requests failed jobs'

    $successRetry = Invoke-Cli @('retry', '--run', '7001', '--yes')
    Assert-True ($successRetry.ExitCode -eq 1 -and $successRetry.Text -match 'cannot be retried') 'end-to-end retry refuses a successful run'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "End-to-end tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
