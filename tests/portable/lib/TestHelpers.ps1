$ErrorActionPreference = 'Stop'

function Initialize-TestEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$TestScriptRoot,
        [Parameter(Mandatory = $true)][string]$Suite,
        [switch]$Keep
    )

    if ($env:GIT_CUSTOMS_TEST_BIN) {
        $script:InstallDir = $env:GIT_CUSTOMS_TEST_BIN
    }
    else {
        $script:InstallDir = Join-Path (Split-Path -Parent (Split-Path -Parent $TestScriptRoot)) 'scripts'
    }
    $script:FakeGhDir = Join-Path (Join-Path $TestScriptRoot 'fixtures') 'fake-gh'
    $script:OriginalPath = $env:Path
    $env:Path = "$($script:FakeGhDir);$($script:InstallDir);$($script:OriginalPath)"
    $script:SuiteRoot = Join-Path $env:TEMP ("git-command-tests-{0}-{1}" -f $Suite, [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:SuiteRoot -Force | Out-Null
    $script:Passed = 0
    $script:Failed = 0
    $script:Failures = New-Object 'System.Collections.Generic.List[string]'
    $script:Keep = [bool]$Keep

    $env:FAKE_GH_STATE = ''
}

function Complete-TestEnvironment {
    if ($null -ne $script:OriginalPath) {
        $env:Path = $script:OriginalPath
    }
    if (-not $script:Keep -and (Test-Path -LiteralPath $script:SuiteRoot)) {
        Remove-Item -LiteralPath $script:SuiteRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output ''
    Write-Output "Tests: $($script:Passed) passed, $($script:Failed) failed."
    if ($script:Failed -gt 0) {
        Write-Output 'Failures:'
        foreach ($failure in @($script:Failures)) {
            Write-Output "  - $failure"
        }
        exit 1
    }
    exit 0
}

function Test-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Output "PASS  $Name"
    }
    catch {
        $script:Failed++
        $message = $_.Exception.Message
        $script:Failures.Add("$Name :: $message")
        Write-Output "FAIL  $Name"
        foreach ($line in @($message -split "\r?\n")) {
            Write-Output "      $line"
        }
    }
}

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-False {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if ($Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Label)
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Label expected '$Expected', got '$Actual'."
    }
}

function Assert-Match {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][string]$Label)
    if ([string]$Text -notmatch $Pattern) {
        throw "$Label did not match /$Pattern/. Output:`n$Text"
    }
}

function Assert-NotMatch {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][string]$Label)
    if ([string]$Text -match $Pattern) {
        throw "$Label unexpectedly matched /$Pattern/. Output:`n$Text"
    }
}

function Assert-Contains {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
    if (-not ([string]$Text).Contains($Value)) {
        throw "$Label did not contain '$Value'. Output:`n$Text"
    }
}

function Assert-ExitCode {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][int]$Expected, [Parameter(Mandatory = $true)][string]$Label)
    if ($Result.ExitCode -ne $Expected) {
        throw "$Label expected exit code $Expected, got $($Result.ExitCode). Output:`n$($Result.Text)`nError:`n$($Result.Error)"
    }
}

function New-TestDirectory {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $script:SuiteRoot $Name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-SetupGit {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repo @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($exitCode -ne 0) {
        throw "setup git $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return [string[]]@($output | ForEach-Object { [string]$_ })
}

function New-TestRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$OriginUrl = 'https://github.com/example/demo.git',
        [switch]$WithoutOrigin
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Invoke-SetupGit $Path @('init', '-b', 'main') | Out-Null
    Invoke-SetupGit $Path @('config', 'user.name', 'Test User') | Out-Null
    Invoke-SetupGit $Path @('config', 'user.email', 'test@example.com') | Out-Null
    Invoke-SetupGit $Path @('config', 'commit.gpgsign', 'false') | Out-Null
    Invoke-SetupGit $Path @('config', 'core.autocrlf', 'false') | Out-Null
    if (-not $WithoutOrigin) {
        Invoke-SetupGit $Path @('remote', 'add', 'origin', $OriginUrl) | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value '# test repository' -Encoding utf8
    Invoke-SetupGit $Path @('add', 'README.md') | Out-Null
    Invoke-SetupGit $Path @('commit', '-m', 'initial commit') | Out-Null
    return $Path
}

function Add-TestCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$Content = 'change'
    )

    Set-Content -LiteralPath (Join-Path $Repo $FileName) -Value $Content -Encoding utf8
    Invoke-SetupGit $Repo @('add', $FileName) | Out-Null
    Invoke-SetupGit $Repo @('commit', '-m', "add $FileName") | Out-Null
    return (& git -C $Repo rev-parse HEAD).Trim()
}

function Set-OriginTracking {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Sha
    )
    Invoke-SetupGit $Repo @('update-ref', "refs/remotes/origin/$Branch", $Sha) | Out-Null
}

function New-TestState {
    param([Parameter(Mandatory = $true)][string]$Name)

    $state = New-TestDirectory "state-$Name"
    $script:CurrentState = $state
    $env:FAKE_GH_STATE = $state
    Set-StateText 'defaultBranch' 'main'
    return $state
}

function Set-StateText {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value = ''
    )
    [System.IO.File]::WriteAllText((Join-Path $script:CurrentState $Name), $Value)
}

function Set-StateJson {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )
    [System.IO.File]::WriteAllText((Join-Path $script:CurrentState $Name), ($Value | ConvertTo-Json -Depth 12 -Compress))
}

function Set-StateFailure {
    param([string[]]$Names)
    Set-StateText 'fail.txt' (($Names -join "`n") + "`n")
}

function Clear-StateFailure {
    $path = Join-Path $script:CurrentState 'fail.txt'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Reset-PrViewCount {
    $path = Join-Path $script:CurrentState 'pr-view-count.txt'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-FakeCalls {
    $path = Join-Path $script:CurrentState 'calls.log'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path)
}

function Clear-FakeCalls {
    $path = Join-Path $script:CurrentState 'calls.log'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$InputText = $null
    )

    $errorFile = [System.IO.Path]::GetTempFileName()
    $output = @()
    $code = 1
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath $Repo
        try {
            if ($null -ne $InputText) {
                $output = $InputText | & git @Arguments 2> $errorFile
            }
            else {
                $output = & git @Arguments 2> $errorFile
            }
            $code = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errorFile) {
            $stderr = [string](Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue)
            $stderr = ($stderr -replace '\s+', ' ').Trim()
        }
        $lines = [string[]]@($output | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            ExitCode = $code
            Output   = $lines
            Text     = ($lines -join "`n")
            Error    = $stderr
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Assert-NoBomAndLf {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "file has a UTF-8 BOM: $Path"
    }
    if ([System.Text.Encoding]::UTF8.GetString($bytes).Contains("`r`n")) {
        throw "file contains CRLF line endings: $Path"
    }
}
