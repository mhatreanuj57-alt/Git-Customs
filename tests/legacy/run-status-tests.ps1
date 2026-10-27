$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-status-tests'
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
    Set-FakeState @{
        workflows = $workflows
        runs = @()
        failures = @{}
        rerunCalls = @()
    }

    $empty = Invoke-Cli @('status')
    Assert-True ($empty.ExitCode -eq 0 -and $empty.Text -match 'No workflow runs found') 'status handles no runs'

    Set-FakeState @{
        workflows = $workflows
        runs = @(
            (New-Run '2001' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'completed' 'success' '2026-10-27T10:00:00Z' 'Main run'),
            (New-Run '2002' 'Build Check' '.github/workflows/ci.yml' '102' 'feature' 'completed' 'failure' '2026-10-27T11:00:00Z' 'Feature run'),
            (New-Run '2003' 'Action Workflow' '.github/workflows/action-workflow.yml' '101' 'main' 'in_progress' '' '2026-10-27T12:00:00Z' 'Older main run')
        )
        failures = @{}
        rerunCalls = @()
    }

    $current = Invoke-Cli @('status')
    Assert-True ($current.ExitCode -eq 0 -and $current.Text -match 'Repository: example/demo' -and $current.Text -match 'Branch: main' -and $current.Text -match '2001' -and $current.Text -notmatch '2002' -and $current.Text -match 'completed/success' -and $current.Text -match 'in_progress') 'status defaults to current branch and prints run columns'

    $all = Invoke-Cli @('status', '--all-branches')
    Assert-True ($all.ExitCode -eq 0 -and $all.Text -match 'all branches' -and $all.Text -match '2001' -and $all.Text -match '2002' -and $all.Text -match '2003') 'status --all-branches includes every branch'

    $branch = Invoke-Cli @('status', '--branch', 'feature')
    Assert-True ($branch.ExitCode -eq 0 -and $branch.Text -match 'Branch: feature' -and $branch.Text -match '2002' -and $branch.Text -notmatch '2001') 'status filters an explicit branch'

    $workflow = Invoke-Cli @('status', '--workflow', 'ci.yml', '--all-branches')
    Assert-True ($workflow.ExitCode -eq 0 -and $workflow.Text -match 'Workflow: Build Check' -and $workflow.Text -match '2002' -and $workflow.Text -notmatch '2001') 'status filters by workflow selector'

    $limit = Invoke-Cli @('status', '--limit', '1')
    $limitLines = @($limit.Text -split "`n" | Where-Object { $_ -match '^\s*200[0-9]' })
    Assert-True ($limit.ExitCode -eq 0 -and $limitLines.Count -eq 1 -and $limit.Text -match '2003') 'status applies the run limit and sorts newest first'

    $badLimit = Invoke-Cli @('status', '--limit', '0')
    Assert-True ($badLimit.ExitCode -eq 1 -and $badLimit.Text -match '--limit must be an integer between') 'status rejects an invalid limit'

    $both = Invoke-Cli @('status', '--branch', 'main', '--all-branches')
    Assert-True ($both.ExitCode -eq 1 -and $both.Text -match 'choose either --branch or --all-branches') 'status rejects conflicting branch filters'

    $missing = Invoke-Cli @('status', '--workflow', 'missing.yml')
    Assert-True ($missing.ExitCode -eq 1 -and $missing.Text -match 'was not found') 'status rejects an unknown workflow'

    Set-FakeState @{
        workflows = $workflows
        runs = @()
        failures = @{ 'run list' = 'simulated run list failure' }
        rerunCalls = @()
    }
    $failure = Invoke-Cli @('status')
    Assert-True ($failure.ExitCode -eq 1 -and $failure.Text -match 'simulated run list failure') 'status surfaces gh run listing failures'

    Set-FakeState @{
        workflows = $workflows
        runs = @()
        failures = @{ 'auth status' = 'not logged in' }
        rerunCalls = @()
    }
    $auth = Invoke-Cli @('status')
    Assert-True ($auth.ExitCode -eq 1 -and $auth.Text -match 'not logged in') 'status surfaces authentication failures'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Status tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
