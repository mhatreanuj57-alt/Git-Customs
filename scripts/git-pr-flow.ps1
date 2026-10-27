$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

$script:CommandPrefix = 'git pr-flow'

try {
    $sharedPath = Join-Path $PSScriptRoot 'git-command-shared.ps1'
    $workflowCorePath = Join-Path $PSScriptRoot 'git-action-workflow-core.ps1'
    $corePath = Join-Path $PSScriptRoot 'git-pr-flow-core.ps1'
    foreach ($requiredPath in @($sharedPath, $workflowCorePath, $corePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "missing required file: $requiredPath"
        }
    }
    . $sharedPath
    . $workflowCorePath
    . $corePath

    $script:ExitCode = 0
    if ($args.Count -eq 0) {
        Invoke-GitPrFlowStatus @()
        exit [int]$script:ExitCode
    }

    $command = [string]$args[0]
    $commandArguments = @()
    if ($args.Count -gt 1) {
        $commandArguments = [string[]]$args[1..($args.Count - 1)]
    }

    switch -Regex ($command.ToLowerInvariant()) {
        '^(?:-h|--help|help)$' {
            Show-GitPrFlowUsage
            exit 0
        }
        '^status$' {
            Invoke-GitPrFlowStatus $commandArguments
            exit [int]$script:ExitCode
        }
        '^create$' {
            Invoke-GitPrFlowCreate $commandArguments
            exit [int]$script:ExitCode
        }
        '^checks$' {
            Invoke-GitPrFlowChecks $commandArguments
            exit [int]$script:ExitCode
        }
        default {
            throw "unknown command '$command'. Run '$($script:CommandPrefix) -h' for usage."
        }
    }
}
catch {
    [Console]::Error.WriteLine("$($script:CommandPrefix): $($_.Exception.Message)")
    exit 1
}
