$ErrorActionPreference = 'Stop'

$testRoot = Join-Path $env:TEMP 'git-action-workflow-init-validate-tests'
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

function Set-FakeState {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Set-RemoteWorkflows {
    param([object[]]$Workflows)
    Set-FakeState @{
        auth = [ordered]@{
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
        workflows = $Workflows
        runs = @()
        failures = @{}
        rerunCalls = @()
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
            Output   = [string[]]@($output | ForEach-Object { [string]$_ })
            Text     = (@($output | ForEach-Object { [string]$_ }) -join "`n")
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
        Pop-Location
        $env:Path = $script:OriginalPath
    }
}

function Invoke-CliWithoutGh {
    param([string[]]$Arguments)

    Push-Location -LiteralPath $repoPath
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $gitDir = Split-Path -Parent (Get-Command git).Source
        $env:Path = "$sourceDir;$gitDir;$(Join-Path $env:SystemRoot 'System32');$(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')"
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
    Set-RemoteWorkflows @()

    $help = Invoke-Cli @('-h')
    Assert-True ($help.ExitCode -eq 0 -and $help.Text -match 'git action-workflow <command>') 'top-level help dispatches through git'
    $initHelp = Invoke-Cli @('init', '-h')
    Assert-True ($initHelp.ExitCode -eq 0 -and $initHelp.Text -match '--dry-run') 'init help dispatches through git'

    $dryRun = Invoke-Cli @('init', '--dry-run')
    $defaultPath = Join-Path $repoPath '.github\workflows\action-workflow.yml'
    Assert-True ($dryRun.ExitCode -eq 0 -and $dryRun.Text -match 'Dry run' -and -not (Test-Path -LiteralPath $defaultPath)) 'init dry-run writes nothing'

    $init = Invoke-Cli @('init')
    Assert-True ($init.ExitCode -eq 0 -and (Test-Path -LiteralPath $defaultPath)) 'init creates the default workflow'
    $bytes = [System.IO.File]::ReadAllBytes($defaultPath)
    $content = [System.IO.File]::ReadAllText($defaultPath)
    Assert-True ($content -match "name: 'Action Workflow'" -and $content -match 'on: \[push, workflow_dispatch\]') 'init writes the expected workflow content'
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'init writes UTF-8 without BOM'
    Assert-True (-not (([System.Text.Encoding]::ASCII.GetString($bytes)).Contains("`r`n"))) 'init writes LF line endings'

    $beforeHash = (Get-FileHash -LiteralPath $defaultPath -Algorithm SHA256).Hash
    $overwrite = Invoke-Cli @('init')
    $afterHash = (Get-FileHash -LiteralPath $defaultPath -Algorithm SHA256).Hash
    Assert-True ($overwrite.ExitCode -eq 1 -and $overwrite.Text -match 'refusing to overwrite' -and $beforeHash -eq $afterHash) 'init refuses to overwrite and preserves content'

    $custom = Invoke-Cli @('init', '--name', 'Build Check', '--file', 'ci')
    $customPath = Join-Path $repoPath '.github\workflows\ci.yml'
    Assert-True ($custom.ExitCode -eq 0 -and (Test-Path -LiteralPath $customPath) -and ([System.IO.File]::ReadAllText($customPath) -match "name: 'Build Check'")) 'init supports custom name and filename'

    $existingPath = Join-Path $repoPath '.github\workflows\existing.yml'
    $existingContent = "name: Existing`non: [push]`njobs:`n  test:`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo hi`n"
    [System.IO.File]::WriteAllText($existingPath, $existingContent, (New-Object System.Text.UTF8Encoding $false))
    $existingHash = (Get-FileHash -LiteralPath $existingPath -Algorithm SHA256).Hash
    $existing = Invoke-Cli @('init', '--file', 'existing.yml')
    Assert-True ($existing.ExitCode -eq 1 -and (Get-FileHash -LiteralPath $existingPath -Algorithm SHA256).Hash -eq $existingHash) 'init never overwrites an unrelated workflow'

    $badPath = Invoke-Cli @('init', '--file', '..\escape.yml')
    Assert-True ($badPath.ExitCode -eq 1 -and $badPath.Text -match 'not valid') 'init rejects path traversal'

    $offline = Invoke-CliWithoutGh @('init', '--file', 'offline.yml', '--name', 'Offline')
    Assert-True ($offline.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $repoPath '.github\workflows\offline.yml'))) 'init works without gh authentication or gh installed'

    $localOnly = Invoke-Cli @('validate')
    Assert-True ($localOnly.ExitCode -eq 0 -and $localOnly.Text -match 'not registered on GitHub' -and $localOnly.Text -match 'Validation passed with') 'validate reports unregistered workflows as warnings'

    $strict = Invoke-Cli @('validate', '--require-remote')
    Assert-True ($strict.ExitCode -eq 1 -and $strict.Text -match 'not registered on GitHub') 'validate --require-remote fails for unregistered workflows'

    Set-RemoteWorkflows @(
        @{ id = 101; name = 'Action Workflow'; path = '.github/workflows/action-workflow.yml'; state = 'active' },
        @{ id = 102; name = 'Build Check'; path = '.github/workflows/ci.yml'; state = 'active' },
        @{ id = 103; name = 'Existing'; path = '.github/workflows/existing.yml'; state = 'active' },
        @{ id = 104; name = 'Offline'; path = '.github/workflows/offline.yml'; state = 'active' }
    )
    $registered = Invoke-Cli @('validate', '--require-remote')
    Assert-True ($registered.ExitCode -eq 0 -and $registered.Text -match 'Validation passed: 4 local workflow' -and $registered.Text -notmatch 'registered but disabled') 'validate accepts registered remote workflows'

    $selected = Invoke-Cli @('validate', '--workflow', 'ci.yml')
    Assert-True ($selected.ExitCode -eq 0 -and $selected.Text -match 'Workflow filter: ci.yml' -and $selected.Text -match 'Local workflows: 1') 'validate selects a workflow by filename'

    Set-RemoteWorkflows @(
        @{ id = 101; name = 'Action Workflow'; path = '.github/workflows/action-workflow.yml'; state = 'disabled' },
        @{ id = 102; name = 'Build Check'; path = '.github/workflows/ci.yml'; state = 'active' },
        @{ id = 103; name = 'Existing'; path = '.github/workflows/existing.yml'; state = 'active' },
        @{ id = 104; name = 'Offline'; path = '.github/workflows/offline.yml'; state = 'active' }
    )
    $disabled = Invoke-Cli @('validate')
    Assert-True ($disabled.ExitCode -eq 0 -and $disabled.Text -match 'registered but disabled') 'validate warns about disabled workflows'

    $brokenPath = Join-Path $repoPath '.github\workflows\broken.yml'
    [System.IO.File]::WriteAllText($brokenPath, 'name: Broken', (New-Object System.Text.UTF8Encoding $false))
    $broken = Invoke-Cli @('validate')
    Assert-True ($broken.ExitCode -eq 1 -and $broken.Text -match 'broken.yml: missing top-level on:' -and $broken.Text -match 'missing top-level jobs:') 'validate rejects structurally invalid workflows'

    $unknown = Invoke-Cli @('validate', '--workflow', 'missing.yml')
    Assert-True ($unknown.ExitCode -eq 1 -and $unknown.Text -match 'was not found locally or remotely') 'validate rejects unknown selectors'

    $beforeStatus = @(git -C $repoPath status --porcelain)
    Assert-True ($beforeStatus.Count -gt 0 -and $beforeStatus -notmatch 'README.md') 'init and validate leave tracked files unchanged'
}
finally {
    Set-Location -LiteralPath $script:OriginalLocation
    $env:Path = $script:OriginalPath
}

Write-Output ''
Write-Output "Init/validate tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) {
    Write-Output ("Failures: " + ($script:Failures -join '; '))
    exit 1
}
exit 0
