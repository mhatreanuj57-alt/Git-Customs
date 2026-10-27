$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-engine-tests'
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

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Details = '')
    if ($Condition) {
        $script:Passed++
        Write-Output "PASS $Name"
    }
    else {
        $script:Failed++
        $script:Failures.Add($Name)
        Write-Output "FAIL $Name $Details"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Name, [string]$Pattern = '')
    try {
        & $Action
        Assert-True $false $Name 'No exception was thrown.'
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($Pattern) -or $_.Exception.Message -match $Pattern) {
            Assert-True $true $Name
        }
        else {
            Assert-True $false $Name "Unexpected error: $($_.Exception.Message)"
        }
    }
}

function Set-FakeState {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Initialize-Fixture {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $repoPath -Force | Out-Null

    git -C $repoPath init -b main | Out-Null
    git -C $repoPath config user.email 'tester@example.com'
    git -C $repoPath config user.name 'Tester'
    Set-Content -LiteralPath (Join-Path $repoPath 'README.md') -Value 'test' -Encoding ASCII
    git -C $repoPath add README.md
    git -C $repoPath commit -m 'Initial commit' | Out-Null
    git -C $repoPath remote add origin 'https://github.com/example/demo.git'

    $auth = [ordered]@{
        hosts = [ordered]@{
            'github.com' = @(
                [ordered]@{
                    state = 'success'
                    active = $true
                    host = 'github.com'
                    login = 'tester'
                    tokenSource = 'keyring'
                    scopes = 'repo, workflow'
                    gitProtocol = 'https'
                }
            )
        }
    }
    $jobs = @(
        [ordered]@{
            databaseId = 7002
            name = 'test'
            status = 'completed'
            conclusion = 'failure'
            log = 'job full log'
            failedLog = 'job failed log'
        },
        [ordered]@{
            databaseId = 7001
            name = 'build'
            status = 'completed'
            conclusion = 'success'
            log = 'job build log'
            failedLog = ''
        }
    )
    $runs = @(
        [ordered]@{
            databaseId = 5003
            workflowDatabaseId = 101
            workflowName = 'CI'
            workflowPath = '.github/workflows/ci.yml'
            displayTitle = 'Latest in progress'
            event = 'push'
            headBranch = 'main'
            headSha = '3333333'
            status = 'in_progress'
            conclusion = $null
            createdAt = '2026-10-27T12:00:00Z'
            url = 'https://github.com/example/demo/actions/runs/5003'
            attempt = 1
            jobs = @()
            log = 'in progress log'
            failedLog = ''
        },
        [ordered]@{
            databaseId = 5002
            workflowDatabaseId = 101
            workflowName = 'CI'
            workflowPath = '.github/workflows/ci.yml'
            displayTitle = 'Failed feature run'
            event = 'push'
            headBranch = 'feature'
            headSha = '2222222'
            status = 'completed'
            conclusion = 'failure'
            createdAt = '2026-10-27T11:00:00Z'
            url = 'https://github.com/example/demo/actions/runs/5002'
            attempt = 1
            jobs = $jobs
            log = 'full run log'
            failedLog = 'failed run log'
        },
        [ordered]@{
            databaseId = 5001
            workflowDatabaseId = 202
            workflowName = 'Deploy'
            workflowPath = '.github/workflows/deploy.yml'
            displayTitle = 'Successful deploy'
            event = 'workflow_dispatch'
            headBranch = 'main'
            headSha = '1111111'
            status = 'completed'
            conclusion = 'success'
            createdAt = '2026-10-27T10:00:00Z'
            url = 'https://github.com/example/demo/actions/runs/5001'
            attempt = 1
            jobs = @()
            log = 'deploy log'
            failedLog = ''
        }
    )
    $workflows = @(
        [ordered]@{ id = 101; name = 'CI'; path = '.github/workflows/ci.yml'; state = 'active' },
        [ordered]@{ id = 202; name = 'Deploy'; path = '.github/workflows/deploy.yml'; state = 'active' },
        [ordered]@{ id = 303; name = 'CI Copy'; path = '.github/workflows/ci-copy.yml'; state = 'disabled' }
    )
    Set-FakeState @{
        auth = $auth
        workflows = $workflows
        runs = $runs
        failures = @{}
        rerunCalls = @()
    }

    $env:FAKE_GH_STATE = $statePath
    $env:FAKE_GH_LOG = $logPath
    $env:Path = "$fakeGhDir;$env:Path"
    Set-Location -LiteralPath $repoPath
}

$script:OriginalPath = $env:Path
$script:OriginalLocation = Get-Location

try {
    Initialize-Fixture
    . (Join-Path $sourceDir 'git-action-workflow-core.ps1')

    $https = ConvertTo-ActionWorkflowGitHubRemoteInfo 'https://github.com/acme/demo.git'
    Assert-True ($https.Host -eq 'github.com' -and $https.FullName -eq 'acme/demo') 'parses HTTPS remote'
    $ssh = ConvertTo-ActionWorkflowGitHubRemoteInfo 'git@github.com:acme/demo.git'
    Assert-True ($ssh.FullName -eq 'acme/demo' -and $ssh.RepoSpec -eq 'acme/demo') 'parses SCP-style SSH remote'
    $sshUrl = ConvertTo-ActionWorkflowGitHubRemoteInfo 'ssh://git@github.com/acme/demo.git'
    Assert-True ($sshUrl.FullName -eq 'acme/demo') 'parses SSH URL remote'
    $enterprise = ConvertTo-ActionWorkflowGitHubRemoteInfo 'https://github.example.com/acme/demo'
    Assert-True ($enterprise.Host -eq 'github.example.com' -and $enterprise.RepoSpec -eq 'github.example.com/acme/demo') 'builds enterprise repo spec'
    Assert-Throws { ConvertTo-ActionWorkflowGitHubRemoteInfo 'C:\repos\demo' } 'rejects local remote' 'owner/repository'
    Assert-Throws { ConvertTo-ActionWorkflowGitHubRemoteInfo 'https://github.com/acme' } 'rejects incomplete remote' 'owner/repository'

    Assert-ActionWorkflowGitAvailable | Out-Null
    Assert-ActionWorkflowGhAvailable | Out-Null
    $auth = Assert-ActionWorkflowGhAuthenticated 'github.com'
    Assert-True ($auth.Login -eq 'tester') 'reads active gh account'

    $context = Get-ActionWorkflowContext
    Assert-True ($context.FullName -eq 'example/demo' -and $context.Branch -eq 'main' -and $context.GhLogin -eq 'tester') 'builds combined GitHub context'

    $workflows = @(Get-ActionWorkflowList $context)
    Assert-True ($workflows.Count -eq 3) 'discovers remote workflows including disabled'
    $ci = Resolve-ActionWorkflow $context 'CI'
    Assert-True ($ci.path -eq '.github/workflows/ci.yml') 'resolves workflow by name'
    $ciByPath = Resolve-ActionWorkflow $context '.github/workflows/ci.yml'
    Assert-True ($ciByPath.id -eq 101) 'resolves workflow by path'
    $ciByFile = Resolve-ActionWorkflow $context 'ci.yml'
    Assert-True ($ciByFile.id -eq 101) 'resolves workflow by filename'
    $ciById = Resolve-ActionWorkflow $context '101'
    Assert-True ($ciById.name -eq 'CI') 'resolves workflow by id'
    Assert-Throws { Resolve-ActionWorkflow $context 'missing.yml' } 'rejects unknown workflow' 'was not found'

    $mainRuns = @(Get-ActionWorkflowRuns -Context $context -Branch 'main' -Limit 10)
    Assert-True ($mainRuns.Count -eq 2 -and $mainRuns[0].databaseId -eq 5003) 'filters and sorts runs by current branch'
    $ciRuns = @(Get-ActionWorkflowRuns -Context $context -Workflow $ci -AllBranches -Limit 10)
    Assert-True ($ciRuns.Count -eq 2) 'filters runs by workflow'
    $single = Get-ActionWorkflowRun $context '5002'
    Assert-True ($single.databaseId -eq 5002 -and $single.conclusion -eq 'failure') 'verifies explicit run id'
    Assert-Throws { Get-ActionWorkflowRun $context 'not-a-run' } 'rejects malformed run id' 'not valid'
    Assert-Throws { Get-ActionWorkflowRun $context '9999' } 'rejects unknown run id' 'not found'

    $latest = Resolve-ActionWorkflowRun -Context $context -Branch 'main'
    Assert-True ($latest.databaseId -eq 5003) 'selects latest verified run for branch'
    $explicit = Resolve-ActionWorkflowRun -Context $context -RunId '5002' -WorkflowSelector 'CI'
    Assert-True ($explicit.databaseId -eq 5002) 'selects explicit run with matching workflow'
    Assert-Throws { Resolve-ActionWorkflowRun -Context $context -RunId '5002' -WorkflowSelector 'Deploy' } 'rejects run/workflow mismatch' 'not workflow'
    Assert-Throws { Resolve-ActionWorkflowRun -Context $context -RunId '5002' -Branch 'main' } 'rejects run/branch mismatch' 'not .main.'

    $jobs = @(Get-ActionWorkflowJobs $context $single)
    Assert-True ($jobs.Count -eq 2) 'discovers run jobs'
    $job = Resolve-ActionWorkflowJob $context $single '7002'
    Assert-True ($job.conclusion -eq 'failure') 'verifies job belongs to run'
    Assert-Throws { Resolve-ActionWorkflowJob $context $single '7001x' } 'rejects malformed job id' 'not valid'
    Assert-Throws { Resolve-ActionWorkflowJob $context $single '9999' } 'rejects job outside run' 'does not belong'

    $options = ConvertTo-ActionWorkflowOptions -Arguments @('--run', '5002', '--failed') -ValueOptions @{ '--run' = 'run' } -SwitchOptions @{ '--failed' = 'failed' }
    Assert-True ($options.run -eq '5002' -and $options.failed -eq $true) 'parses shared options'
    $inlineOptions = ConvertTo-ActionWorkflowOptions -Arguments @('--run=5002', '--all') -ValueOptions @{ '--run' = 'run' } -SwitchOptions @{ '--all' = 'all' }
    Assert-True ($inlineOptions.run -eq '5002' -and $inlineOptions.all -eq $true) 'parses inline option values'
    Assert-Throws { ConvertTo-ActionWorkflowOptions -Arguments @('--run') -ValueOptions @{ '--run' = 'run' } -SwitchOptions @{} } 'rejects missing option value' 'requires a value'
    Assert-Throws { ConvertTo-ActionWorkflowOptions -Arguments @('--unknown') -ValueOptions @{} -SwitchOptions @{} } 'rejects unknown option' 'unknown option'

    $template = New-ActionWorkflowTemplate 'Action Workflow'
    Assert-True ($template -match "name: 'Action Workflow'" -and $template -match 'on: \[push, workflow_dispatch\]' -and $template -match 'jobs:') 'builds workflow template'
    $validShape = Test-ActionWorkflowLocalWorkflow ([pscustomobject]@{ Content = $template })
    Assert-True ($validShape.Count -eq 0) 'accepts valid local workflow shape'
    $invalidShape = Test-ActionWorkflowLocalWorkflow ([pscustomobject]@{ Content = 'name: broken' })
    Assert-True ($invalidShape.Count -eq 2) 'rejects workflow missing on and jobs'

    $env:FAKE_GH_STATE = $statePath
    $authState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $authState.auth.hosts.'github.com'[0].active = $false
    [System.IO.File]::WriteAllText($statePath, ($authState | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
    $script:ActionWorkflowAuthCache = @{}
    Assert-Throws { Assert-ActionWorkflowGhAuthenticated 'github.com' } 'rejects gh without an active account' 'no active authenticated'

    $authState.auth.hosts.'github.com'[0].active = $true
    $authState.failures = [pscustomobject]@{ 'workflow list' = 'workflow API failed' }
    [System.IO.File]::WriteAllText($statePath, ($authState | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
    Assert-Throws { Get-ActionWorkflowList $context } 'surfaces gh workflow discovery failure' 'workflow API failed'

    $gitOnlyPath = @(
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0'),
        (Split-Path -Parent (Get-Command git).Source)
    ) -join ';'
    $env:Path = $gitOnlyPath
    Assert-Throws { Assert-ActionWorkflowGhAvailable } 'reports missing gh' 'not installed'
    $env:Path = $script:OriginalPath

    $env:Path = @(
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    ) -join ';'
    Assert-Throws { Assert-ActionWorkflowGitAvailable } 'reports missing git' 'not installed'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Engine tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
