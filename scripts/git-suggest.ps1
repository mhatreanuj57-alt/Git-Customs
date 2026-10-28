$ErrorActionPreference = 'Continue'

if ($args -contains '--help' -or $args -contains '-h') {
    Write-Output 'Usage: git suggest [--combined]'
    Write-Output ''
    Write-Output 'Suggests diff-based Conventional Commit commands for the current repository.'
    Write-Output 'Use --combined for one commit across all pending paths. Nothing is executed.'
    Write-Output 'Requires a Git working tree with an origin remote and a checked-out branch.'
    exit 0
}

$combined = $args -contains '--combined'
$unknown = @($args | Where-Object { $_ -ne '--combined' })
if ($unknown.Count -gt 0) {
    [Console]::Error.WriteLine("git suggest: unknown argument(s): $($unknown -join ' ')")
    exit 1
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
}
catch {
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("git suggest: $Message")
    exit 1
}

$corePath = Join-Path $PSScriptRoot 'git-suggest-core.ps1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    Fail "missing required file: $corePath"
}

try {
    . $corePath
}
catch {
    Fail "could not load the shared detection code: $($_.Exception.Message)"
}

try {
    $context = Get-GitRepositoryContext
    $plan = Get-GitSuggestionPlan $context
}
catch {
    Fail $_.Exception.Message
}

if ($plan.Entries.Count -eq 0) {
    Write-Output "Repository `"$($context.RepoName)`" is up to date."
    exit 0
}

Write-Output "# Repository `"$($context.RepoName)`" | branch: $($context.Branch)"
Write-Output "# Run from: $($context.RepoRoot)"
Write-Output "# Changes: $($plan.Entries.Count) file(s) | added $($plan.AddedCount), modified $($plan.ModifiedCount), deleted $($plan.DeletedCount), untracked $($plan.UntrackedCount) | staged $($plan.StagedCount) (staged overlaps)"
Write-Output '# Suggested commands only; nothing was executed.'
Write-Output ''

if ($combined) {
    $commitPaths = @($plan.Suggestions | ForEach-Object { $_.CommitPaths } | Select-Object -Unique)
    foreach ($suggestion in $plan.Suggestions) { if ($suggestion.DisplayAddCommand) { Write-Output $suggestion.DisplayAddCommand } }
    $quotedMessage = ConvertTo-PowerShellLiteral (Get-GitCombinedMessage $plan.Suggestions)
    $quotedPaths = ($commitPaths | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ' '
    Write-Output "git commit -m $quotedMessage -- $quotedPaths"
    Write-Output ''
    Write-Output ('git push origin ' + (Format-PushBranch $context.Branch))
    exit 0
}

foreach ($suggestion in $plan.Suggestions) {
    if ($null -ne $suggestion.DisplayAddCommand) {
        Write-Output $suggestion.DisplayAddCommand
    }
    Write-Output $suggestion.DisplayCommitCommand
}

Write-Output ''
Write-Output ('git push origin ' + (Format-PushBranch $context.Branch))
