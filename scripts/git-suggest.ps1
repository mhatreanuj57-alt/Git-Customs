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

function Get-SuggestionDetails {
    param($Suggestion)

    $paths = @($Suggestion.Path)
    if ($Suggestion.OldPath) { $paths = @($Suggestion.OldPath, $Suggestion.Path) }
    $gitArgs = @('-C', $context.RepoRoot, 'diff', '--no-ext-diff', '--unified=0')
    if ($context.HasHead) { $gitArgs += @('HEAD', '--') } else { $gitArgs += @('--') }
    $gitArgs += $paths
    $diff = Invoke-GitDetect $gitArgs
    $text = $diff.Output -join "`n"
    $binary = $text -match '^Binary files '
    if ($Suggestion.IsUntracked -and (Test-Path -LiteralPath (Join-Path $context.RepoRoot $Suggestion.Path) -PathType Leaf)) {
        $file = Join-Path $context.RepoRoot $Suggestion.Path
        $bytes = [IO.File]::ReadAllBytes($file)
        $binary = $binary -or ($bytes -contains 0)
        if (-not $binary) { $text = (([IO.File]::ReadAllText($file) -split "`r?`n") | ForEach-Object { "+$_" }) -join "`n" }
    }

    $name = [IO.Path]::GetFileName($Suggestion.Path)
    if ($name -match '(?i)(secret|credential|token|password|\.env)') { $name = 'configuration' }
    if ($Suggestion.IsRename) { return [pscustomobject]@{ Summary = "Renames '$($Suggestion.OldPath)' to '$($Suggestion.Path)'."; Message = "refactor: rename $($Suggestion.OldPath) to $($Suggestion.Path)" } }
    if ($binary) {
        if ($Suggestion.IsDeleted) { return [pscustomobject]@{ Summary = 'Removes a binary file; its contents cannot be summarized as text.'; Message = "chore: remove binary asset $name" } }
        if ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') { return [pscustomobject]@{ Summary = 'Adds a binary file; its contents cannot be summarized as text.'; Message = "chore: add binary asset $name" } }
        return [pscustomobject]@{ Summary = 'Changes a binary file; its contents cannot be summarized as text.'; Message = "chore: update binary asset $name" }
    }

    $added = @($text -split "`r?`n" | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' })
    $removed = @($text -split "`r?`n" | Where-Object { $_ -match '^-' -and $_ -notmatch '^---' })
    $changes = ($added + $removed) -join "`n"
    $summary = 'Changes text, but its purpose is unclear from the diff.'
    $message = 'chore: update repository content'
    if ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') { $summary = 'Adds text content; its purpose is unclear from the diff.'; $message = 'chore: add repository content' }
    if ($Suggestion.IsDeleted) { $summary = 'Removes a file; its purpose is unclear from the diff.'; $message = 'chore: remove repository content' }

    if ($changes -match '(?i)(@media|breakpoint|responsive)' -and $changes -match '(?i)(nav|menu|header)') {
        $summary = 'Adds or updates responsive navigation styles.'; $message = 'feat: add responsive navigation'
    } elseif ($changes -match '(?i)(loginRedirect|returnUrl|callbackUrl|redirect)' -and $changes -match '(?i)(login|signin|account|redirect)') {
        $summary = 'Changes login or callback redirect handling.'; $message = 'fix: correct login redirect'
    } elseif ($changes -match '(?i)(focus-visible|aria-|keyboard|tabindex)' ) {
        $summary = 'Changes keyboard or assistive-technology interaction.'; $message = 'fix: improve keyboard accessibility'
    } elseif ($changes -match '(?i)(validate|validation|invalid)' ) {
        $summary = 'Changes input validation behavior.'; $message = 'fix: improve input validation'
    } elseif ($changes -match '(?i)(?:function|def|class)\s+([A-Za-z][A-Za-z0-9_-]{1,40})') {
        $symbol = [regex]::Match($changes, '(?i)(?:function|def|class)\s+([A-Za-z][A-Za-z0-9_-]{1,40})').Groups[1].Value
        if ($Suggestion.IsDeleted) { $summary = "Removes the $symbol implementation."; $message = "refactor: remove $symbol" }
        elseif ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') { $summary = "Adds the $symbol implementation."; $message = "feat: add $symbol" }
        else { $summary = "Changes the $symbol implementation."; $message = "refactor: update $symbol behavior" }
    } elseif ($Suggestion.Path -match '(?i)(^|[/\\])README(?:\.[^/\\]+)?$' -and $added.Count -gt 0) {
        $summary = 'Adds or updates project documentation.'; $message = 'docs: update project documentation'
    } elseif ($Suggestion.Path -match '(?i)(^|[/\\])tests?[/\\]|\.(test|spec)\.' -and $changes) {
        $summary = 'Changes automated test coverage.'; $message = 'test: update automated coverage'
    } elseif ($Suggestion.IsDeleted) {
        $summary = 'Removes content; its purpose is not clear from the changed lines.'; $message = 'chore: remove repository content'
    } elseif ($Suggestion.IsUntracked -or $Suggestion.X -eq 'A') {
        $summary = 'Adds new content; the diff does not identify a more specific purpose.'; $message = 'chore: add repository content'
    } elseif ($added.Count -gt 0 -and $removed.Count -eq 0) {
        $summary = 'Adds content; its purpose is not clear from the changed lines.'; $message = 'chore: add repository content'
    } elseif ($removed.Count -gt 0 -and $added.Count -eq 0) {
        $summary = 'Removes content; its purpose is not clear from the changed lines.'; $message = 'chore: remove repository content'
    }
    [pscustomobject]@{ Summary = $summary; Message = $message }
}

foreach ($suggestion in $plan.Suggestions) {
    $details = Get-SuggestionDetails $suggestion
    $suggestion | Add-Member -NotePropertyName Summary -NotePropertyValue $details.Summary -Force
    $suggestion | Add-Member -NotePropertyName Message -NotePropertyValue $details.Message -Force
    $quotedMessage = ConvertTo-PowerShellLiteral $suggestion.Message
    $quotedPaths = ($suggestion.CommitPaths | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ' '
    $suggestion | Add-Member -NotePropertyName DisplayCommitCommand -NotePropertyValue "git commit -m $quotedMessage -- $quotedPaths" -Force
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
Write-Output 'Changed files:'
foreach ($suggestion in $plan.Suggestions) {
    $label = if ($suggestion.IsRename) { "renamed: $($suggestion.OldPath) -> $($suggestion.Path)" } elseif ($suggestion.IsDeleted) { "deleted: $($suggestion.Path)" } elseif ($suggestion.IsUntracked -or $suggestion.X -eq 'A') { "added: $($suggestion.Path)" } else { "modified: $($suggestion.Path)" }
    Write-Output ("  {0}" -f $label)
    Write-Output ("    Summary: {0}" -f $suggestion.Summary)
    Write-Output ("    Recommended commit: {0}" -f $suggestion.Message)
}
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
