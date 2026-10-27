$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-watch-tests'
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
        [string]$Title
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

    $workflows = @(
        @{ id = 101; name = 'Action Workflow'; path = '.github/workflows/action-workflow.yml'; state = 'active' },
        @{ id = 102; name = 'Build Check'; path = '.github/workflows/ci.yml'; state = 'active' }
    )
    $baseRuns = @(
        (New-Run '3001' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'completed' 'success' '2026-10-27T10:00:00Z' 'Main success'),
        (New-Run '3002' 'Build Check' '.github/workflows/ci.yml' '102' 'feature' 'completed' 'failure' '2026-10-27T11:00:00Z' 'Feature failure')
    )
    Set-FakeState @{ workflows = $workflows; runs = $baseRuns; failures = @{}; rerunCalls = @() }

    $success = Invoke-Cli @('watch')
    Assert-True ($success.ExitCode -eq 0 -and $success.Text -match 'Run:\s+3001' -and $success.Text -match 'completed/success' -and $success.Text -match 'already completed') 'watch reports an already successful latest run with exit 0'

    $failure = Invoke-Cli @('watch', '--run', '3002')
    Assert-True ($failure.ExitCode -eq 1 -and $failure.Text -match 'Run:\s+3002' -and $failure.Text -match 'completed/failure') 'watch uses explicit run without defaulting its branch and returns failure'

    $mismatch = Invoke-Cli @('watch', '--run', '3002', '--branch', 'main')
    Assert-True ($mismatch.ExitCode -eq 1 -and $mismatch.Text -match "is for branch 'feature'") 'watch verifies an explicit branch for an explicit run'

    $workflowMatch = Invoke-Cli @('watch', '--run', '3002', '--workflow', 'ci.yml')
    Assert-True ($workflowMatch.ExitCode -eq 1 -and $workflowMatch.Text -match 'completed/failure') 'watch verifies an explicit workflow for an explicit run'

    $workflowMismatch = Invoke-Cli @('watch', '--run', '3002', '--workflow', 'action-workflow.yml')
    Assert-True ($workflowMismatch.ExitCode -eq 1 -and $workflowMismatch.Text -match "belongs to 'Build Check'") 'watch rejects a run/workflow mismatch'

    $unknown = Invoke-Cli @('watch', '--run', '999999')
    Assert-True ($unknown.ExitCode -eq 1 -and $unknown.Text -match 'was not found or is not accessible') 'watch rejects an unknown run'

    Set-FakeState @{
        workflows = $workflows
        runs = @($baseRuns) + @((New-Run '3003' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'in_progress' '' '2026-10-27T12:00:00Z' 'Running'))
        failures = @{}
        rerunCalls = @()
    }
    $timeout = Invoke-Cli @('watch', '--run', '3003', '--interval', '1', '--timeout', '1')
    Assert-True ($timeout.ExitCode -eq 1 -and $timeout.Text -match 'Watching run 3003' -and $timeout.Text -match 'timed out after 1 second') 'watch times out an in-progress run'

    Set-FakeState @{
        workflows = $workflows
        runs = @($baseRuns) + @((New-Run '3004' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'in_progress' '' '2026-10-27T13:00:00Z' 'Transitioning'))
        failures = @{}
        rerunCalls = @()
        transitions = @{
            '3004' = @{
                remaining = 1
                status = 'completed'
                conclusion = 'success'
            }
        }
    }
    $transitioned = Invoke-Cli @('watch', '--run', '3004', '--interval', '1', '--timeout', '5')
    Assert-True ($transitioned.ExitCode -eq 0 -and $transitioned.Text -match 'Watching run 3004' -and $transitioned.Text -match 'Updated:' -and $transitioned.Text -match 'finished: completed/success') 'watch polls an in-progress run until it completes'

    $badInterval = Invoke-Cli @('watch', '--interval', '0')
    Assert-True ($badInterval.ExitCode -eq 1 -and $badInterval.Text -match '--interval must be an integer') 'watch rejects an invalid interval'

    $badTimeout = Invoke-Cli @('watch', '--timeout', '0')
    Assert-True ($badTimeout.ExitCode -eq 1 -and $badTimeout.Text -match '--timeout must be an integer') 'watch rejects an invalid timeout'

    $both = Invoke-Cli @('watch', '--branch', 'main', '--all-branches')
    Assert-True ($both.ExitCode -eq 1 -and $both.Text -match 'choose either --branch or --all-branches') 'watch rejects conflicting branch filters'

    Set-FakeState @{ workflows = $workflows; runs = $baseRuns; failures = @{ 'run view' = 'simulated run view failure' }; rerunCalls = @() }
    $viewFailure = Invoke-Cli @('watch')
    Assert-True ($viewFailure.ExitCode -eq 1 -and $viewFailure.Text -match 'simulated run view failure') 'watch surfaces gh run lookup failures'

    Set-FakeState @{ workflows = $workflows; runs = $baseRuns; failures = @{ 'auth status' = 'not logged in' }; rerunCalls = @() }
    $authFailure = Invoke-Cli @('watch')
    Assert-True ($authFailure.ExitCode -eq 1 -and $authFailure.Text -match 'not logged in') 'watch surfaces authentication failures'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Watch tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
