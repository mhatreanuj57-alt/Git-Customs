$ErrorActionPreference = 'Continue'

if ($args -contains '--help' -or $args -contains '-h') {
    Write-Output 'Usage: git suggest'
    Write-Output ''
    Write-Output 'Suggests per-file git add, git commit, and git push commands for the'
    Write-Output 'current repository. Commands are printed only; nothing is executed.'
    Write-Output 'Requires a Git working tree with an origin remote and a checked-out branch.'
    exit 0
}

if ($args.Count -gt 0) {
    [Console]::Error.WriteLine("git suggest: unknown argument(s): $($args -join ' ')")
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

foreach ($suggestion in $plan.Suggestions) {
    if ($null -ne $suggestion.DisplayAddCommand) {
        Write-Output $suggestion.DisplayAddCommand
    }
    Write-Output $suggestion.DisplayCommitCommand
}

Write-Output ''
Write-Output ('git push origin ' + (Format-PushBranch $context.Branch))
