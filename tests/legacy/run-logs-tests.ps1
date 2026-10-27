$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-logs-tests'
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

function New-Job {
    param([string]$Id, [string]$Name, [string]$Conclusion, [string]$Log, [string]$FailedLog)
    [ordered]@{
        databaseId = [long]$Id
        name = $Name
        status = 'completed'
        conclusion = $Conclusion
        log = $Log
        failedLog = $FailedLog
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
        [object[]]$Jobs,
        [string]$Log,
        [string]$FailedLog
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
        log = $Log
        failedLog = $FailedLog
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
    $runs = @(
        (New-Run '4001' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'completed' 'success' '2026-10-27T10:00:00Z' 'Main success' @(
            (New-Job '501' 'build' 'success' 'job 501 full log' '')
        ) 'run 4001 full log' ''),
        (New-Run '4002' 'Build Check' '.github/workflows/ci.yml' '102' 'feature' 'completed' 'failure' '2026-10-27T11:00:00Z' 'Feature failure' @(
            (New-Job '502' 'test' 'failure' 'job 502 full log' 'job 502 failed step log'),
            (New-Job '503' 'deploy' 'success' 'job 503 full log' '')
        ) 'run 4002 full log' 'run 4002 failed step log')
    )
    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }

    $latest = Invoke-Cli @('logs')
    Assert-True ($latest.ExitCode -eq 0 -and $latest.Text -match 'Run:\s+4001' -and $latest.Text -match 'Logs:\s+full logs' -and $latest.Text -match 'run 4001 full log') 'logs shows latest branch run logs'

    $fullFailedRun = Invoke-Cli @('logs', '--run', '4002')
    Assert-True ($fullFailedRun.ExitCode -eq 0 -and $fullFailedRun.Text -match 'completed/failure' -and $fullFailedRun.Text -match 'run 4002 full log') 'logs retrieves a failed run with exit 0'

    $job = Invoke-Cli @('logs', '--run', '4002', '--job', '502')
    Assert-True ($job.ExitCode -eq 0 -and $job.Text -match 'Job:\s+502 \(test\)' -and $job.Text -match 'job 502 full log' -and $job.Text -notmatch 'run 4002 full log') 'logs shows one verified job'

    $latestJob = Invoke-Cli @('logs', '--job', '501')
    Assert-True ($latestJob.ExitCode -eq 0 -and $latestJob.Text -match 'Run:\s+4001' -and $latestJob.Text -match 'job 501 full log') 'logs resolves a job on the latest matching run'

    $failedLogs = Invoke-Cli @('logs', '--run', '4002', '--failed')
    Assert-True ($failedLogs.ExitCode -eq 0 -and $failedLogs.Text -match 'Logs:\s+failed steps' -and $failedLogs.Text -match 'run 4002 failed step log') 'logs --failed shows failed run steps'

    $failedJob = Invoke-Cli @('logs', '--run', '4002', '--failed', '--job', '502')
    Assert-True ($failedJob.ExitCode -eq 0 -and $failedJob.Text -match 'job 502 failed step log' -and $failedJob.Text -notmatch 'job 503') 'logs --failed narrows to a verified failed job'

    $successfulFailed = Invoke-Cli @('logs', '--run', '4001', '--failed')
    Assert-True ($successfulFailed.ExitCode -eq 1 -and $successfulFailed.Text -match 'has no failed jobs') 'logs --failed rejects a run without failed jobs'

    $successfulJobFailed = Invoke-Cli @('logs', '--run', '4002', '--failed', '--job', '503')
    Assert-True ($successfulJobFailed.ExitCode -eq 1 -and $successfulJobFailed.Text -match 'job ''503'' has no failed steps') 'logs --failed rejects a successful job'

    $badJob = Invoke-Cli @('logs', '--run', '4002', '--job', '999')
    Assert-True ($badJob.ExitCode -eq 1 -and $badJob.Text -match 'does not belong to workflow run') 'logs rejects a job outside the run'

    $malformedJob = Invoke-Cli @('logs', '--run', '4002', '--job', 'abc')
    Assert-True ($malformedJob.ExitCode -eq 1 -and $malformedJob.Text -match 'job id ''abc'' is not valid') 'logs rejects a malformed job id'

    $workflow = Invoke-Cli @('logs', '--workflow', 'ci.yml', '--all-branches')
    Assert-True ($workflow.ExitCode -eq 0 -and $workflow.Text -match 'Run:\s+4002' -and $workflow.Text -match 'run 4002 full log') 'logs filters by workflow'

    $branch = Invoke-Cli @('logs', '--branch', 'feature')
    Assert-True ($branch.ExitCode -eq 0 -and $branch.Text -match 'Run:\s+4002' -and $branch.Text -match 'Branch:\s+feature') 'logs filters by branch'

    $both = Invoke-Cli @('logs', '--branch', 'main', '--all-branches')
    Assert-True ($both.ExitCode -eq 1 -and $both.Text -match 'choose either --branch or --all-branches') 'logs rejects conflicting branch filters'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{ 'run log' = 'simulated log failure' }; rerunCalls = @() }
    $logFailure = Invoke-Cli @('logs', '--run', '4001')
    Assert-True ($logFailure.ExitCode -eq 1 -and $logFailure.Text -match 'simulated log failure') 'logs surfaces gh log retrieval failures'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{ 'auth status' = 'not logged in' }; rerunCalls = @() }
    $authFailure = Invoke-Cli @('logs')
    Assert-True ($authFailure.ExitCode -eq 1 -and $authFailure.Text -match 'not logged in') 'logs surfaces authentication failures'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Logs tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
