[CmdletBinding()]
param([switch]$Keep)

. (Join-Path $PSScriptRoot 'lib\TestHelpers.ps1')
Initialize-TestEnvironment -TestScriptRoot $PSScriptRoot -Suite 'security' -Keep:$Keep

function New-SecurityRepo {
    param([Parameter(Mandatory = $true)][string]$Name)
    return (New-TestRepo -Path (Join-Path $script:SuiteRoot $Name))
}

function Write-RepoFile {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $path = Join-Path $Repo $RelativePath
    $parent = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $Content)
}

function Add-SafeWorkflow {
    param([Parameter(Mandatory = $true)][string]$Repo)
    Write-RepoFile -Repo $Repo -RelativePath '.github\workflows\ci.yml' -Content @'
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
}

try {
    Test-Case 'security-check help is available' {
        $repo = New-SecurityRepo 'help'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '-h')
        Assert-ExitCode $result 0 'security-check -h'
        Assert-Match $result.Text 'Usage: git security-check' 'help output'
        Assert-Match $result.Text '--secrets-only' 'help options'
    }

    Test-Case 'security-check passes a clean repository' {
        $repo = New-SecurityRepo 'clean'
        Add-SafeWorkflow $repo
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check')
        Assert-ExitCode $result 0 'clean security-check'
        Assert-Match $result.Text 'Credentials .* no findings' 'clean credentials'
        Assert-Match $result.Text 'Workflows .* no findings' 'clean workflows'
        Assert-Match $result.Text '0 error\(s\), 0 warning\(s\)' 'clean summary'
        Assert-Match $result.Text 'Security check passed' 'clean verdict'
    }

    Test-Case 'security-check detects and redacts secret patterns' {
        $repo = New-SecurityRepo 'secrets'
        $token = 'ghp_abcdefghijklmnopqrstuvwxyz123456'
        Write-RepoFile -Repo $repo -RelativePath 'config.txt' -Content @"
GITHUB_TOKEN=$token
AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF
-----BEGIN RSA PRIVATE KEY-----
"@
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only')
        Assert-ExitCode $result 1 'secret detection'
        Assert-Match $result.Text '\[ERROR\].*config\.txt:1 - GitHub token \(ghp_\*\*\*' 'github token finding'
        Assert-Match $result.Text 'config\.txt:2 - AWS access key' 'aws key finding'
        Assert-Match $result.Text 'config\.txt:3 - Private key block' 'private key finding'
        Assert-NotMatch $result.Text ([regex]::Escape($token)) 'redacted token'
        Assert-NotMatch $result.Text 'AKIA1234567890ABCDEF' 'redacted aws key'
        Assert-Match $result.Text 'Security check failed' 'security verdict'
    }

    Test-Case 'security-check flags sensitive credential filenames' {
        $repo = New-SecurityRepo 'sensitive-filename'
        Write-RepoFile -Repo $repo -RelativePath '.env' -Content 'SAFE_PLACEHOLDER=1'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only')
        Assert-ExitCode $result 1 'sensitive filename'
        Assert-Match $result.Text '\[ERROR\] \.env - Sensitive file \(environment file\)' 'env finding'
    }

    Test-Case 'security-check warns about possible hard-coded credentials' {
        $repo = New-SecurityRepo 'assignment'
        Write-RepoFile -Repo $repo -RelativePath 'settings.txt' -Content 'api_key = "abcdefgh12345678"'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only')
        Assert-ExitCode $result 0 'assignment warning'
        Assert-Match $result.Text '\[WARN\].*Possible hard-coded credential' 'assignment warning output'
        Assert-Match $result.Text 'Security check completed with warnings' 'warning verdict'

        $strict = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only', '--strict')
        Assert-ExitCode $strict 1 'assignment strict'
        Assert-Match $strict.Text 'Security check failed' 'strict verdict'
    }

    Test-Case 'security-check ignores placeholder credential values' {
        $repo = New-SecurityRepo 'placeholder'
        Write-RepoFile -Repo $repo -RelativePath 'settings.txt' -Content 'api_key = "your_api_key_here"'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only')
        Assert-ExitCode $result 0 'placeholder'
        Assert-Match $result.Text '0 warning\(s\)' 'placeholder warning count'
    }

    Test-Case 'security-check detects risky workflow patterns' {
        $repo = New-SecurityRepo 'risky-workflow'
        Write-RepoFile -Repo $repo -RelativePath '.github\workflows\risky.yml' -Content @'
name: Risky
on:
  pull_request_target:
permissions: write-all
jobs:
  build:
    runs-on: ubuntu-latest
    secrets: inherit
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - run: echo "${{ github.event.pull_request.title }}"
      - run: curl https://example.com/install.sh | sh
'@
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--workflows-only')
        Assert-ExitCode $result 1 'risky workflow'
        Assert-Match $result.Text 'pull_request_target checkout' 'checkout finding'
        Assert-Match $result.Text 'write-all permissions' 'write-all finding'
        Assert-Match $result.Text 'Privileged pull_request_target' 'privileged finding'
        Assert-Match $result.Text 'Inherited secrets' 'secrets finding'
        Assert-Match $result.Text 'Remote script execution' 'remote script finding'
        Assert-Match $result.Text 'Expression injection' 'injection finding'
        Assert-Match $result.Text 'Unpinned action' 'unpinned finding'
        Assert-Match $result.Text "Action actions/checkout is pinned to 'v4'" 'unpinned detail'
        Assert-NotMatch $result.Text 'Credentials \(' 'workflows-only should skip credentials'
    }

    Test-Case 'security-check warns for missing permissions and unpinned actions' {
        $repo = New-SecurityRepo 'workflow-warnings'
        Write-RepoFile -Repo $repo -RelativePath '.github\workflows\ci.yml' -Content @'
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
'@
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--workflows-only')
        Assert-ExitCode $result 0 'workflow warnings'
        Assert-Match $result.Text 'Missing permissions' 'missing permissions warning'
        Assert-Match $result.Text 'Unpinned action' 'unpinned warning'
        Assert-Match $result.Text '2 warning\(s\)' 'workflow warning count'

        $strict = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--workflows-only', '--strict')
        Assert-ExitCode $strict 1 'workflow strict'
    }

    Test-Case 'security-check scans staged content when requested' {
        $repo = New-SecurityRepo 'staged'
        $token = 'ghp_abcdefghijklmnopqrstuvwxyz123456'
        Write-RepoFile -Repo $repo -RelativePath 'staged.txt' -Content "GITHUB_TOKEN=$token"
        Invoke-SetupGit $repo @('add', 'staged.txt') | Out-Null
        Remove-Item -LiteralPath (Join-Path $repo 'staged.txt') -Force

        $staged = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--staged', '--secrets-only')
        Assert-ExitCode $staged 1 'staged scan'
        Assert-Match $staged.Text 'staged\.txt:1 - GitHub token' 'staged finding'
        Assert-Match $staged.Text 'Source: staged content' 'staged source'

        $workingTree = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only')
        Assert-ExitCode $workingTree 0 'working tree after deletion'
        Assert-Match $workingTree.Text 'no findings' 'deleted file not scanned from working tree'
    }

    Test-Case 'security-check ignores ignored files' {
        $repo = New-SecurityRepo 'ignored'
        Write-RepoFile -Repo $repo -RelativePath '.gitignore' -Content "secret.log`n"
        Write-RepoFile -Repo $repo -RelativePath 'secret.log' -Content 'GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz123456'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only')
        Assert-ExitCode $result 0 'ignored file'
        Assert-Match $result.Text 'no findings' 'ignored finding'
    }

    Test-Case 'security-check mode flags are mutually exclusive' {
        $repo = New-SecurityRepo 'conflicting-modes'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--secrets-only', '--workflows-only')
        Assert-ExitCode $result 1 'conflicting modes'
        Assert-Match $result.Error 'cannot be used together' 'mode error'
    }

    Test-Case 'security-check fails outside a Git repository' {
        $directory = New-TestDirectory 'not-a-repo'
        $result = Invoke-TestGit -Repo $directory -Arguments @('security-check')
        Assert-ExitCode $result 1 'outside repository'
        Assert-Match $result.Error 'not inside a Git working tree' 'outside repository error'
    }

    Test-Case 'security-check rejects unknown options' {
        $repo = New-SecurityRepo 'unknown-option'
        $result = Invoke-TestGit -Repo $repo -Arguments @('security-check', '--bogus')
        Assert-ExitCode $result 1 'unknown option'
        Assert-Match $result.Error 'unknown option' 'unknown option error'
    }
}
finally {
    Complete-TestEnvironment
}
