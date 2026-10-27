$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-retry-tests'
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

function Get-RerunCalls {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    return [object[]]@($state.rerunCalls)
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

function Invoke-CliWithInput {
    param(
        [string]$InputText,
        [string[]]$Arguments
    )

    $gitCommand = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $gitCommand
    $startInfo.Arguments = 'action-workflow ' + ($Arguments -join ' ')
    $startInfo.WorkingDirectory = $repoPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['Path'] = "$fakeGhDir;$sourceDir;$script:OriginalPath"
    $startInfo.EnvironmentVariables['FAKE_GH_STATE'] = $statePath
    $startInfo.EnvironmentVariables['FAKE_GH_LOG'] = $logPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    if ($InputText.Length -gt 0) {
        $process.StandardInput.WriteLine($InputText)
    }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text     = ($stdout + "`n" + $stderr)
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
        (New-Run '5001' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'completed' 'success' '2026-10-27T10:00:00Z' 'Success' @(
            (New-Job '601' 'build' 'success')
        )),
        (New-Run '5002' 'Build Check' '.github/workflows/ci.yml' '102' 'feature' 'completed' 'failure' '2026-10-27T11:00:00Z' 'Failed' @(
            (New-Job '602' 'test' 'failure'),
            (New-Job '603' 'deploy' 'success')
        )),
        (New-Run '5003' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'in_progress' '' '2026-10-27T12:00:00Z' 'Running' @(
            (New-Job '604' 'build' '')
        )),
        (New-Run '5004' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'completed' 'failure' '2026-10-27T09:00:00Z' 'No failed jobs' @(
            (New-Job '605' 'build' 'success')
        ))
    )

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $failedRetry = Invoke-Cli @('retry', '--run', '5002', '--yes')
    $calls = @(Get-RerunCalls)
    Assert-True ($failedRetry.ExitCode -eq 0 -and $failedRetry.Text -match 'Failed jobs: 1' -and $failedRetry.Text -match 'Requested failed jobs re-run' -and $calls.Count -eq 1 -and $calls[0].Mode -eq 'failed' -and $calls[0].RunId -eq '5002') 'retry --yes re-runs failed jobs after verification'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $allRetry = Invoke-Cli @('retry', '--run', '5002', '--all', '--yes')
    $calls = @(Get-RerunCalls)
    Assert-True ($allRetry.ExitCode -eq 0 -and $allRetry.Text -match 'Requested all jobs re-run' -and $calls.Count -eq 1 -and $calls[0].Mode -eq 'all') 'retry --all re-runs every job'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $success = Invoke-Cli @('retry', '--run', '5001', '--yes')
    Assert-True ($success.ExitCode -eq 1 -and $success.Text -match 'cannot be retried' -and @(Get-RerunCalls).Count -eq 0) 'retry refuses a successful run'

    $running = Invoke-Cli @('retry', '--run', '5003', '--yes')
    Assert-True ($running.ExitCode -eq 1 -and $running.Text -match 'is in_progress; wait' -and @(Get-RerunCalls).Count -eq 0) 'retry refuses an in-progress run'

    $noFailed = Invoke-Cli @('retry', '--run', '5004', '--yes')
    Assert-True ($noFailed.ExitCode -eq 1 -and $noFailed.Text -match 'has no failed jobs to re-run' -and @(Get-RerunCalls).Count -eq 0) 'retry refuses a failed run without failed jobs'

    $noFailedAll = Invoke-Cli @('retry', '--run', '5004', '--all', '--yes')
    $calls = @(Get-RerunCalls)
    Assert-True ($noFailedAll.ExitCode -eq 0 -and $calls.Count -eq 1 -and $calls[0].Mode -eq 'all') 'retry --all permits a failed run without failed jobs'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $feature = Invoke-Cli @('retry', '--run', '5002', '--workflow', 'ci.yml', '--yes')
    Assert-True ($feature.ExitCode -eq 0 -and @(Get-RerunCalls).Count -eq 1) 'retry accepts an explicit feature-branch run without a branch filter'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $branchMismatch = Invoke-Cli @('retry', '--run', '5002', '--branch', 'main', '--yes')
    Assert-True ($branchMismatch.ExitCode -eq 1 -and $branchMismatch.Text -match "is for branch 'feature'" -and @(Get-RerunCalls).Count -eq 0) 'retry verifies an explicit branch'

    $workflowMismatch = Invoke-Cli @('retry', '--run', '5002', '--workflow', 'action-workflow.yml', '--yes')
    Assert-True ($workflowMismatch.ExitCode -eq 1 -and $workflowMismatch.Text -match "belongs to 'Build Check'" -and @(Get-RerunCalls).Count -eq 0) 'retry verifies an explicit workflow'

    $unknown = Invoke-Cli @('retry', '--run', '999999', '--yes')
    Assert-True ($unknown.ExitCode -eq 1 -and $unknown.Text -match 'was not found or is not accessible') 'retry rejects an unknown run'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $declined = Invoke-CliWithInput 'n' @('retry', '--run', '5002')
    Assert-True ($declined.ExitCode -eq 1 -and $declined.Text -match 'retry cancelled' -and @(Get-RerunCalls).Count -eq 0) 'retry cancels when confirmation is declined'

    $missingConfirmation = Invoke-CliWithInput '' @('retry', '--run', '5002')
    Assert-True ($missingConfirmation.ExitCode -eq 1 -and $missingConfirmation.Text -match 'confirmation is required' -and @(Get-RerunCalls).Count -eq 0) 'retry requires confirmation when stdin is empty'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{}; rerunCalls = @() }
    $confirmed = Invoke-CliWithInput 'y' @('retry', '--run', '5002')
    Assert-True ($confirmed.ExitCode -eq 0 -and $confirmed.Text -match 'Requested failed jobs re-run' -and @(Get-RerunCalls).Count -eq 1) 'retry proceeds when confirmation is accepted'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{ 'run rerun' = 'simulated rerun failure' }; rerunCalls = @() }
    $rerunFailure = Invoke-Cli @('retry', '--run', '5002', '--yes')
    Assert-True ($rerunFailure.ExitCode -eq 1 -and $rerunFailure.Text -match 'simulated rerun failure') 'retry surfaces gh rerun failures'

    Set-FakeState @{ workflows = $workflows; runs = $runs; failures = @{ 'auth status' = 'not logged in' }; rerunCalls = @() }
    $authFailure = Invoke-Cli @('retry', '--run', '5002', '--yes')
    Assert-True ($authFailure.ExitCode -eq 1 -and $authFailure.Text -match 'not logged in') 'retry surfaces authentication failures'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Retry tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
