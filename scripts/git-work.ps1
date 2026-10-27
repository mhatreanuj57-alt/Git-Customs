$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

$script:CommandPrefix = 'git work'

try {
    $sharedPath = Join-Path $PSScriptRoot 'git-command-shared.ps1'
    $workflowCorePath = Join-Path $PSScriptRoot 'git-action-workflow-core.ps1'
    $corePath = Join-Path $PSScriptRoot 'git-work-core.ps1'
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
        Invoke-GitWorkList
        exit 0
    }

    $command = [string]$args[0]
    $commandArguments = @()
    if ($args.Count -gt 1) {
        $commandArguments = [string[]]$args[1..($args.Count - 1)]
    }

    switch -Regex ($command.ToLowerInvariant()) {
        '^(?:-h|--help|help)$' {
            Show-GitWorkUsage
            exit 0
        }
        '^(?:list|ls)$' {
            Invoke-GitWorkList $commandArguments
            exit [int]$script:ExitCode
        }
        '^add$' {
            Invoke-GitWorkAdd $commandArguments
            exit [int]$script:ExitCode
        }
        '^remove$' {
            Invoke-GitWorkRemove $commandArguments
            exit [int]$script:ExitCode
        }
        '^prune$' {
            Invoke-GitWorkPrune $commandArguments
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
