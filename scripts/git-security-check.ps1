$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

$script:CommandPrefix = 'git security-check'

try {
    $sharedPath = Join-Path $PSScriptRoot 'git-command-shared.ps1'
    $workflowCorePath = Join-Path $PSScriptRoot 'git-action-workflow-core.ps1'
    $corePath = Join-Path $PSScriptRoot 'git-security-check-core.ps1'
    foreach ($requiredPath in @($sharedPath, $workflowCorePath, $corePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "missing required file: $requiredPath"
        }
    }
    . $sharedPath
    . $workflowCorePath
    . $corePath

    $script:ExitCode = 0
    Invoke-GitSecurityCheck ([string[]]$args)
    exit [int]$script:ExitCode
}
catch {
    [Console]::Error.WriteLine("$($script:CommandPrefix): $($_.Exception.Message)")
    exit 1
}
