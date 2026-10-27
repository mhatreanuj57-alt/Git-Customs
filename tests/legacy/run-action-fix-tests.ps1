$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-fix-tests'
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
$remotePath = Join-Path $testRoot 'origin.git'
$requirementsPath = Join-Path $repoPath 'requirements.txt'
$ciPath = Join-Path $repoPath '.github\workflows\ci.yml'
$nodePath = Join-Path $repoPath '.github\workflows\node.yml'

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$script:OriginalPath = $env:Path
$script:OriginalLocation = Get-Location
$script:Workflows = @(
    [ordered]@{ id = 102; name = 'Build Check'; path = '.github/workflows/ci.yml'; state = 'active' },
    [ordered]@{ id = 103; name = 'Node Check'; path = '.github/workflows/node.yml'; state = 'active' }
)

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
        if (-not [string]::IsNullOrWhiteSpace($script:LastOutput)) {
            Write-Output ("  output: " + ($script:LastOutput -replace "`r?`n", ' | '))
        }
    }
}

function New-Job {
    param([string]$Id, [string]$Name, [string]$Conclusion)
    [ordered]@{
        databaseId = [long]$Id
        name = $Name
        status = 'completed'
        conclusion = $Conclusion
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
        [string]$HeadSha,
        [string]$FailedLog,
        [object[]]$Jobs,
        [int]$Attempt = 1
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
        attempt = $Attempt
        headSha = $HeadSha
        url = "https://github.com/example/demo/actions/runs/$Id"
        failedLog = $FailedLog
        jobs = @($Jobs)
    }
}

function Invoke-Git {
    param([string[]]$Arguments)
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $repoPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join "`n")"
    }
    return [string[]]@($output | ForEach-Object { [string]$_ })
}

function Get-Head {
    return ((Invoke-Git @('rev-parse', 'HEAD')) -join '').Trim()
}

function Reset-Worktree {
    $null = Invoke-Git @('reset', '--hard', 'HEAD')
    $null = Invoke-Git @('clean', '-fd')
}

function Set-FakeState {
    param([hashtable]$State)
    [System.IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
}

function Get-FakeState {
    return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}

function Set-Scenario {
    param(
        [object[]]$Runs,
        [hashtable]$Failures = @{},
        $RerunTransitions = $null,
        $AutoRecovery = $null
    )
    $state = [ordered]@{
        workflows = $script:Workflows
        runs = @($Runs)
        failures = $Failures
        rerunCalls = @()
    }
    if ($null -ne $RerunTransitions) {
        $state.rerunTransitions = $RerunTransitions
    }
    if ($null -ne $AutoRecovery) {
        $state.autoRecovery = $AutoRecovery
    }
    Set-FakeState $state
}

function Invoke-Cli {
    param([string[]]$Arguments)

    Push-Location -LiteralPath $repoPath
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:Path = "$fakeGhDir;$sourceDir;$script:OriginalPath"
        $env:FAKE_GH_STATE = $statePath
        $env:FAKE_GH_LOG = $logPath
        $output = & git action-fix @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $script:LastOutput = (@($output | ForEach-Object { [string]$_ }) -join "`n")
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
    $startInfo.Arguments = 'action-fix ' + ($Arguments -join ' ')
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
    $script:LastOutput = $stdout + "`n" + $stderr
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Text     = ($stdout + "`n" + $stderr)
    }
}

function New-PythonRun {
    param([string]$Id, [string]$Head, [string]$Log = "ModuleNotFoundError: No module named 'yaml'")
    return New-Run -Id $Id -WorkflowName 'Build Check' -WorkflowPath '.github/workflows/ci.yml' -WorkflowId '102' `
        -Branch 'main' -Status 'completed' -Conclusion 'failure' -CreatedAt '2026-10-27T10:00:00Z' `
        -Title 'Python failure' -HeadSha $Head -FailedLog $Log -Jobs @((New-Job '9201' 'test' 'failure'))
}

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
    git init --bare $remotePath | Out-Null
    git -C $repoPath init -b main | Out-Null
    git -C $repoPath config user.email 'tester@example.com'
    git -C $repoPath config user.name 'Tester'
    git -C $repoPath config core.autocrlf false
    git -C $repoPath config core.safecrlf false

    $ciContent = @(
        'name: Build Check',
        'on: [push]',
        'jobs:',
        '  test:',
        '    runs-on: ubuntu-latest',
        '    steps:',
        '      - uses: actions/checkout@v4',
        '      - run: pip install -r requirements.txt',
        "      - run: python -c `"import yaml`""
    ) -join "`n"
    $nodeContent = @(
        'name: Node Check',
        'on: [push]',
        'jobs:',
        '  build:',
        '    runs-on: ubuntu-latest',
        '    steps:',
        '      - uses: actions/checkout@v4',
        '      - uses: actions/setup-node@v4',
        '        with:',
        '          node-version: 18',
        '      - run: npm ci'
    ) -join "`n"

    New-Item -ItemType Directory -Path (Join-Path $repoPath '.github\workflows') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repoPath 'README.md'), "# demo`n", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($requirementsPath, "requests==2.32.0`n", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $repoPath 'package.json'), "{`n  `"name`": `"demo`",`n  `"version`": `"1.0.0`"`n}`n", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($ciPath, $ciContent + "`n", (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($nodePath, $nodeContent + "`n", (New-Object System.Text.UTF8Encoding $false))

    $null = Invoke-Git @('add', '.')
    $null = Invoke-Git @('commit', '-m', 'Initial commit')
    $null = Invoke-Git @('remote', 'add', 'origin', 'https://github.com/example/demo.git')
    $rewriteUrl = 'file:///' + (($remotePath -replace '\\', '/'))
    $null = Invoke-Git @('config', '--add', "url.$rewriteUrl.pushInsteadOf", 'https://github.com/example/demo.git')
    $null = Invoke-Git @('push', '-u', 'origin', 'main')
    $baseHead = Get-Head

    $env:FAKE_GH_STATE = $statePath
    $env:FAKE_GH_LOG = $logPath

    $help = Invoke-Cli @('-h')
    Assert-True ($help.ExitCode -eq 0 -and $help.Text -match 'Usage: git action-fix' -and $help.Text -match '--dry-run') 'action-fix help is available'

    $defaultRun = New-PythonRun '8100' $baseHead
    Set-Scenario @($defaultRun)
    $noArguments = Invoke-CliWithInput 'n' @()
    Assert-True ($noArguments.ExitCode -eq 1 -and $noArguments.Text -match 'Run:\s+8100' -and $noArguments.Text -match 'fix cancelled') 'action-fix without arguments diagnoses the latest failed run'

    $run = New-PythonRun '8101' $baseHead
    Set-Scenario @($run)
    $beforeRequirements = [System.IO.File]::ReadAllText($requirementsPath)
    $dryRun = Invoke-Cli @('--run', '8101', '--dry-run')
    Assert-True ($dryRun.ExitCode -eq 0 -and $dryRun.Text -match 'Missing Python dependency' -and $dryRun.Text -match '\+ PyYAML' -and $dryRun.Text -match 'Dry run' -and [System.IO.File]::ReadAllText($requirementsPath) -eq $beforeRequirements) 'action-fix dry run proposes a Python dependency without editing'

    $declined = Invoke-CliWithInput 'n' @('--run', '8101')
    Assert-True ($declined.ExitCode -eq 1 -and $declined.Text -match 'fix cancelled' -and [System.IO.File]::ReadAllText($requirementsPath) -eq $beforeRequirements) 'action-fix cancels the first approval without editing'

    $missingConfirmation = Invoke-CliWithInput '' @('--run', '8101')
    Assert-True ($missingConfirmation.ExitCode -eq 1 -and $missingConfirmation.Text -match 'confirmation is required' -and [System.IO.File]::ReadAllText($requirementsPath) -eq $beforeRequirements) 'action-fix requires confirmation when stdin is empty'

    $headBeforeDecline = Get-Head
    $secondDeclined = Invoke-CliWithInput "y`r`nn" @('--run', '8101')
    $statusText = (Invoke-Git @('status', '--porcelain=v1')) -join "`n"
    Assert-True ($secondDeclined.ExitCode -eq 1 -and $secondDeclined.Text -match 'Recovery cancelled' -and (Get-Head) -eq $headBeforeDecline -and $statusText -match 'requirements\.txt' -and [System.IO.File]::ReadAllText($requirementsPath) -match 'PyYAML') 'declining the second approval leaves the approved edit uncommitted'
    Reset-Worktree

    [System.IO.File]::WriteAllText((Join-Path $repoPath '.github\workflows\broken.yml'), "name: Broken`n", (New-Object System.Text.UTF8Encoding $false))
    $null = Invoke-Git @('add', '.github/workflows/broken.yml')
    $null = Invoke-Git @('commit', '-m', 'Add intentionally broken workflow')
    $null = Invoke-Git @('push', 'origin', 'main')
    $badHead = Get-Head
    $badRun = New-PythonRun '8102' $badHead
    Set-Scenario @($badRun)
    $validationFailed = Invoke-CliWithInput 'y' @('--run', '8102')
    $statusText = (Invoke-Git @('status', '--porcelain=v1', '--untracked-files=all')) -join "`n"
    Assert-True ($validationFailed.ExitCode -eq 1 -and $validationFailed.Text -match 'workflow validation failed' -and $validationFailed.Text -match 'rolled back' -and (Get-Head) -eq $badHead -and [System.IO.File]::ReadAllText($requirementsPath) -match '^requests==2.32.0' -and $validationFailed.Text -notmatch 'Commit and push' -and [string]::IsNullOrWhiteSpace($statusText)) 'action-fix rolls back when local validation fails'
    Remove-Item -LiteralPath (Join-Path $repoPath '.github\workflows\broken.yml') -Force
    $null = Invoke-Git @('add', '-A')
    $null = Invoke-Git @('commit', '-m', 'Remove intentionally broken workflow')
    $null = Invoke-Git @('push', 'origin', 'main')
    $baseHead = Get-Head

    $mismatched = New-PythonRun '8103' ('0' * 40)
    Set-Scenario @($mismatched)
    $headMismatch = Invoke-CliWithInput 'y' @('--run', '8103')
    Assert-True ($headMismatch.ExitCode -eq 1 -and $headMismatch.Text -match 'does not match the failed run commit' -and [System.IO.File]::ReadAllText($requirementsPath) -match '^requests==2.32.0') 'action-fix refuses an edit when HEAD is not the failed commit'

    $dirtyRun = New-PythonRun '8104' $baseHead
    Set-Scenario @($dirtyRun)
    [System.IO.File]::WriteAllText((Join-Path $repoPath 'dirty.txt'), 'dirty', (New-Object System.Text.UTF8Encoding $false))
    $dirty = Invoke-CliWithInput 'y' @('--run', '8104')
    Remove-Item -LiteralPath (Join-Path $repoPath 'dirty.txt') -Force
    Assert-True ($dirty.ExitCode -eq 1 -and $dirty.Text -match 'working tree is not clean' -and [System.IO.File]::ReadAllText($requirementsPath) -match '^requests==2.32.0') 'action-fix refuses an edit with a dirty worktree'

    $branchRun = New-PythonRun '8105' $baseHead
    $branchRun.headBranch = 'feature'
    Set-Scenario @($branchRun)
    $branchMismatch = Invoke-CliWithInput 'y' @('--run', '8105')
    Assert-True ($branchMismatch.ExitCode -eq 1 -and $branchMismatch.Text -match "belongs to branch 'feature'" -and [System.IO.File]::ReadAllText($requirementsPath) -match '^requests==2.32.0') 'action-fix refuses an edit from another branch'

    $remoteRun = New-PythonRun '8106' $baseHead
    Set-Scenario @($remoteRun)
    $null = Invoke-Git @('update-ref', 'refs/remotes/origin/main', "$baseHead^")
    $remoteMismatch = Invoke-CliWithInput 'y' @('--run', '8106')
    $null = Invoke-Git @('update-ref', 'refs/remotes/origin/main', $baseHead)
    Assert-True ($remoteMismatch.ExitCode -eq 1 -and $remoteMismatch.Text -match 'not synchronized with origin/main' -and [System.IO.File]::ReadAllText($requirementsPath) -match '^requests==2.32.0') 'action-fix refuses an edit when the upstream tracking ref is stale'

    $fakeToken = 'ghp_' + ('A' * 30)
    $secretRun = New-PythonRun '8107' $baseHead "ModuleNotFoundError: No module named 'yaml'`nGITHUB_TOKEN=$fakeToken"
    Set-Scenario @($secretRun)
    $secret = Invoke-Cli @('--run', '8107')
    Assert-True ($secret.ExitCode -eq 1 -and $secret.Text -match 'Credential-like value' -and $secret.Text -notmatch [regex]::Escape($fakeToken) -and $secret.Text -match '\[REDACTED\]' -and [System.IO.File]::ReadAllText($requirementsPath) -match '^requests==2.32.0' -and @((Get-FakeState).rerunCalls).Count -eq 0) 'action-fix redacts leaked credentials and refuses edits and retries'

    $authRun = New-PythonRun '8108' $baseHead "remote: Invalid username or password.`nfatal: Authentication failed for 'https://github.com/example/demo.git/'"
    Set-Scenario @($authRun)
    $auth = Invoke-Cli @('--run', '8108')
    Assert-True ($auth.ExitCode -eq 1 -and $auth.Text -match 'Authentication or secret configuration failure' -and $auth.Text -match 'No automatic change or retry' -and @((Get-FakeState).rerunCalls).Count -eq 0) 'action-fix does not retry authentication failures'

    $transientRun = New-PythonRun '8109' $baseHead 'fatal: unable to access https://github.com/example/demo.git/: Could not resolve host: github.com'
    $rerunTransitions = [ordered]@{
        '8109' = [ordered]@{ attempt = 2; status = 'completed'; conclusion = 'success' }
    }
    Set-Scenario @($transientRun) -RerunTransitions $rerunTransitions
    $transientDry = Invoke-Cli @('--run', '8109', '--dry-run')
    Assert-True ($transientDry.ExitCode -eq 0 -and $transientDry.Text -match 'Network or service failure' -and @((Get-FakeState).rerunCalls).Count -eq 0) 'action-fix dry run never requests a retry'

    $transient = Invoke-CliWithInput 'y' @('--run', '8109', '--interval', '1', '--timeout', '5', '--discovery-timeout', '5')
    $state = Get-FakeState
    $calls = @($state.rerunCalls)
    Assert-True ($transient.ExitCode -eq 0 -and $transient.Text -match 'Recovery succeeded' -and $calls.Count -eq 1 -and $calls[0].RunId -eq '8109' -and $calls[0].Mode -eq 'failed') 'action-fix retries an approved transient failure and verifies recovery'

    $unknownRun = New-PythonRun '8110' $baseHead 'AssertionError: expected 1 but got 2'
    Set-Scenario @($unknownRun)
    $unknown = Invoke-Cli @('--run', '8110')
    Assert-True ($unknown.ExitCode -eq 1 -and $unknown.Text -match 'Test or assertion failure' -and $unknown.Text -match 'No automatic change or retry' -and @((Get-FakeState).rerunCalls).Count -eq 0) 'action-fix never retries an unrecognized test failure'

    $noLogRun = New-PythonRun '8111' $baseHead
    Set-Scenario @($noLogRun) -Failures @{ 'run log' = 'simulated log outage' }
    $noLogs = Invoke-Cli @('--run', '8111')
    Assert-True ($noLogs.ExitCode -eq 1 -and $noLogs.Text -match 'simulated log outage' -and $noLogs.Text -match 'No actionable logs were available' -and @((Get-FakeState).rerunCalls).Count -eq 0) 'action-fix refuses to act when logs are unavailable'

    $olderFailure = New-PythonRun '8112' $baseHead
    $successRun = New-Run -Id '8113' -WorkflowName 'Build Check' -WorkflowPath '.github/workflows/ci.yml' -WorkflowId '102' `
        -Branch 'main' -Status 'completed' -Conclusion 'success' -CreatedAt '2026-10-27T11:00:00Z' `
        -Title 'Success' -HeadSha $baseHead -Jobs @((New-Job '9213' 'test' 'success'))
    Set-Scenario @($olderFailure, $successRun)
    $success = Invoke-Cli @()
    Assert-True ($success.ExitCode -eq 1 -and $success.Text -match 'there is no failed run to repair') 'action-fix requires the selected latest run to be failed'

    $runningRun = New-Run -Id '8114' -WorkflowName 'Build Check' -WorkflowPath '.github/workflows/ci.yml' -WorkflowId '102' `
        -Branch 'main' -Status 'in_progress' -Conclusion '' -CreatedAt '2026-10-27T12:00:00Z' `
        -Title 'Running' -HeadSha $baseHead -Jobs @((New-Job '9214' 'test' ''))
    Set-Scenario @($olderFailure, $runningRun)
    $running = Invoke-Cli @()
    Assert-True ($running.ExitCode -eq 1 -and $running.Text -match 'wait for it to finish') 'action-fix refuses an in-progress latest run'

    $nodeBefore = [System.IO.File]::ReadAllText($nodePath)
    $nodeRun = New-Run -Id '8115' -WorkflowName 'Node Check' -WorkflowPath '.github/workflows/node.yml' -WorkflowId '103' `
        -Branch 'main' -Status 'completed' -Conclusion 'failure' -CreatedAt '2026-10-27T13:00:00Z' `
        -Title 'Node failure' -HeadSha $baseHead `
        -FailedLog "npm ERR! code EBADENGINE`nnpm ERR! Required: {`"node`":`">=20`"}`nnpm ERR! Unsupported engine for package" `
        -Jobs @((New-Job '9215' 'build' 'failure'))
    Set-Scenario @($nodeRun)
    $nodeDry = Invoke-Cli @('--run', '8115', '--dry-run')
    Assert-True ($nodeDry.ExitCode -eq 0 -and $nodeDry.Text -match 'Node.js 20 is required' -and $nodeDry.Text -match 'node-version: 18' -and $nodeDry.Text -match 'node-version: 20' -and [System.IO.File]::ReadAllText($nodePath) -eq $nodeBefore) 'action-fix proposes a Node.js major update without editing'

    $npmRun = New-Run -Id '8116' -WorkflowName 'Node Check' -WorkflowPath '.github/workflows/node.yml' -WorkflowId '103' `
        -Branch 'main' -Status 'completed' -Conclusion 'failure' -CreatedAt '2026-10-27T14:00:00Z' `
        -Title 'npm failure' -HeadSha $baseHead `
        -FailedLog "npm error The ``npm ci`` command can only install with an existing package-lock.json" `
        -Jobs @((New-Job '9216' 'build' 'failure'))
    Set-Scenario @($npmRun)
    $npmDry = Invoke-Cli @('--run', '8116', '--dry-run')
    Assert-True ($npmDry.ExitCode -eq 0 -and $npmDry.Text -match 'npm ci cannot find a lockfile' -and $npmDry.Text -match 'npm install' -and $npmDry.Text -notmatch '\+ npm ci' -and [System.IO.File]::ReadAllText($nodePath) -eq $nodeBefore) 'action-fix proposes npm install only when the lockfile is absent'

    $fullRun = New-PythonRun '8120' $baseHead
    $autoRecovery = [ordered]@{
        baseHeadSha = $baseHead
        workflowName = 'Build Check'
        workflowPath = '.github/workflows/ci.yml'
        workflowDatabaseId = 102
        branch = 'main'
        status = 'completed'
        conclusion = 'success'
        title = 'Recovery'
    }
    Set-Scenario @($fullRun) -AutoRecovery $autoRecovery
    $headBeforeFull = Get-Head
    $full = Invoke-CliWithInput "y`r`ny" @('--run', '8120', '--interval', '1', '--timeout', '5', '--discovery-timeout', '5')
    $headAfterFull = Get-Head
    $remoteHead = ((git --git-dir=$remotePath rev-parse main) -join '').Trim()
    $statusText = (Invoke-Git @('status', '--porcelain=v1', '--untracked-files=all')) -join "`n"
    $requirementsAfter = [System.IO.File]::ReadAllText($requirementsPath)
    $commitSubject = (Invoke-Git @('log', '-1', '--pretty=%s')) -join ''
    $recoveryState = Get-FakeState
    $recoveryRun = @($recoveryState.runs | Where-Object { [string]$_.headSha -eq $headAfterFull })
    Assert-True ($full.ExitCode -eq 0 -and $full.Text -match 'Applied: requirements.txt' -and $full.Text -match 'Validation: PASS' -and $full.Text -match 'Pushed: origin/main' -and $full.Text -match 'Recovery succeeded' -and $headAfterFull -cne $headBeforeFull -and $remoteHead -eq $headAfterFull -and $requirementsAfter -match '(?m)^PyYAML$' -and $commitSubject -eq 'Fix CI: add PyYAML dependency' -and [string]::IsNullOrWhiteSpace($statusText) -and $recoveryRun.Count -eq 1) 'action-fix completes the approved edit, push, and verified recovery end to end'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Action-fix tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
