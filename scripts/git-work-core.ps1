function Show-GitWorkUsage {
    Write-Output 'Usage: git work [command] [options]'
    Write-Output ''
    Write-Output 'Create, inspect, and remove isolated Git worktrees safely.'
    Write-Output ''
    Write-Output 'Commands:'
    Write-Output '  list    List worktrees (default)'
    Write-Output '  add     Add a worktree for a new or existing branch'
    Write-Output '  remove  Remove a clean worktree after confirmation'
    Write-Output '  prune   Preview or remove stale worktree metadata'
    Write-Output ''
    Write-Output "Run '$($script:CommandPrefix) <command> -h' for command options."
}

function Show-GitWorkListHelp {
    Write-Output 'Usage: git work list'
    Write-Output ''
    Write-Output 'Lists every worktree, its branch, HEAD, and whether it is the current or main worktree.'
}

function Show-GitWorkAddHelp {
    Write-Output 'Usage: git work add <branch> [--base <ref>] [--path <directory>]'
    Write-Output ''
    Write-Output 'Adds a worktree. If the branch does not exist, it is created from --base'
    Write-Output '(default: HEAD). If it exists, it is checked out in the new worktree.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --base <ref>       Commit, branch, or tag for a new branch (default: HEAD)'
    Write-Output '  --path <dir>       Worktree directory (default: <repo-parent>/<repo>-worktrees/<branch>)'
    Write-Output ''
    Write-Output 'The branch, base, and target path are validated before anything is created.'
}

function Show-GitWorkRemoveHelp {
    Write-Output 'Usage: git work remove <path-or-branch> [--force] [--yes]'
    Write-Output ''
    Write-Output 'Removes a linked worktree after confirmation. The branch is not deleted.'
    Write-Output 'The main worktree and the worktree containing the current directory are refused.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --force  Allow removal of a dirty worktree; discarded changes are permanent'
    Write-Output '  --yes    Skip the interactive confirmation prompt'
}

function Show-GitWorkPruneHelp {
    Write-Output 'Usage: git work prune [--apply] [--dry-run] [--yes]'
    Write-Output ''
    Write-Output 'Previews stale worktree metadata by default. --apply removes it after'
    Write-Output 'confirmation. No branch or commit is deleted.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --apply    Remove stale worktree metadata'
    Write-Output '  --dry-run  Explicitly preview only (default)'
    Write-Output '  --yes      Skip the confirmation prompt when used with --apply'
}

function Get-GitWorkCurrentRoot {
    $root = Get-GitCommandRepoRoot
    try {
        return [System.IO.Path]::GetFullPath($root)
    }
    catch {
        return $root
    }
}

function Find-GitWorkEntry {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $entries = @(Get-GitCommandWorktrees $RepoRoot)
    $matches = @($entries | Where-Object { $_.Branch -ieq $Selector })
    if ($matches.Count -eq 0) {
        $resolved = $null
        try {
            $resolved = [System.IO.Path]::GetFullPath($Selector)
        }
        catch {
        }
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            $matches = @($entries | Where-Object { $_.FullPath -ieq $resolved })
        }
    }
    if ($matches.Count -eq 0) {
        throw "no worktree matches '$Selector'. Run 'git work list' to see available worktrees."
    }
    if ($matches.Count -gt 1) {
        throw "selector '$Selector' matches more than one worktree."
    }
    return $matches[0]
}

function Invoke-GitWorkList {
    param([string[]]$Arguments = @())

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitWorkListHelp
        return
    }
    if (@($Arguments).Count -gt 0) {
        throw "unexpected argument '$($Arguments[0])'. Run '$($script:CommandPrefix) work list -h' for usage."
    }

    $root = Get-GitWorkCurrentRoot
    $entries = @(Get-GitCommandWorktrees $root)
    if ($entries.Count -eq 0) {
        Write-Output 'No worktrees found.'
        return
    }

    Write-Output ('{0,-46} {1,-24} {2,-12} {3}' -f 'PATH', 'BRANCH', 'HEAD', 'STATUS')
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        $status = New-Object 'System.Collections.Generic.List[string]'
        if ($entry.FullPath -ieq $root) {
            $status.Add('current')
        }
        if ($i -eq 0) {
            $status.Add('main')
        }
        if ($entry.Detached) {
            $status.Add('detached')
        }
        if ($entry.Locked) {
            $status.Add('locked')
        }
        if ($entry.Prunable) {
            $status.Add('prunable')
        }
        if (-not $entry.Exists) {
            $status.Add('missing')
        }
        if ($status.Count -eq 0) {
            $status.Add('linked')
        }
        $branch = $entry.Branch
        if ([string]::IsNullOrWhiteSpace($branch)) {
            $branch = '(detached)'
        }
        $path = $entry.Path
        if ($path.Length -gt 46) {
            $path = '...' + $path.Substring($path.Length - 43)
        }
        Write-Output ('{0,-46} {1,-24} {2,-12} {3}' -f $path, $branch, (Format-GitCommandShortSha $entry.Head), ($status -join ', '))
    }
    Write-Output ''
    Write-Output ("{0} worktree(s)." -f $entries.Count)
}

function Invoke-GitWorkAdd {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitWorkAddHelp
        return
    }
    if (@($Arguments).Count -eq 0) {
        throw "a branch name is required. Run '$($script:CommandPrefix) work add -h' for usage."
    }

    $branch = Assert-GitCommandBranchName ([string]$Arguments[0])
    $optionArgs = @()
    if (@($Arguments).Count -gt 1) {
        $optionArgs = [string[]]$Arguments[1..($Arguments.Count - 1)]
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $optionArgs `
        -ValueOptions @{ '--base' = 'Base'; '--path' = 'Path' } `
        -SwitchOptions @{}

    $root = Get-GitWorkCurrentRoot
    $base = 'HEAD'
    if ($options.ContainsKey('Base')) {
        $base = [string]$options['Base']
    }
    if ($base.StartsWith('-')) {
        throw "base '$base' is not valid."
    }

    $baseCheck = Invoke-GitCommand -RepoRoot $root -Arguments @('rev-parse', '--verify', '--quiet', "$base^{commit}") -AllowFailure
    if ($baseCheck.ExitCode -ne 0) {
        throw "base '$base' does not resolve to a commit."
    }

    $branchCheck = Invoke-GitCommand -RepoRoot $root -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch") -AllowFailure
    $branchExists = ($branchCheck.ExitCode -eq 0)

    $entries = @(Get-GitCommandWorktrees $root)
    if ($branchExists) {
        $checkedOut = @($entries | Where-Object { $_.Branch -ieq $branch })
        if ($checkedOut.Count -gt 0) {
            throw "branch '$branch' is already checked out at '$($checkedOut[0].Path)'."
        }
    }

    $targetPath = ''
    if ($options.ContainsKey('Path')) {
        $targetPath = [string]$options['Path']
        if ($targetPath.StartsWith('-')) {
            throw "path '$targetPath' is not valid."
        }
        try {
            $targetPath = [System.IO.Path]::GetFullPath($targetPath)
        }
        catch {
            throw "path '$targetPath' is not valid."
        }
    }
    else {
        $parent = Split-Path -Parent $root
        $repoName = Split-Path -Leaf $root
        $slug = ConvertTo-GitCommandSafeSlug $branch
        $targetPath = Join-Path (Join-Path $parent "$repoName-worktrees") $slug
    }

    if (Test-Path -LiteralPath $targetPath) {
        throw "target path already exists: $targetPath"
    }
    $rootPrefix = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($targetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "target path must be outside the current worktree: $targetPath"
    }

    $parentPath = Split-Path -Parent $targetPath
    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    }

    $gitArguments = @('worktree', 'add')
    if (-not $branchExists) {
        $gitArguments += @('-b', $branch)
    }
    $gitArguments += @($targetPath)
    if ($branchExists) {
        $gitArguments += @($branch)
    }
    else {
        $gitArguments += @($base)
    }

    $result = Invoke-GitCommand -RepoRoot $root -Arguments $gitArguments
    foreach ($line in @($result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Output ([string]$line)
        }
    }
    Write-Output ''
    Write-Output "Created worktree: $targetPath"
    if ($branchExists) {
        Write-Output "Checked out existing branch: $branch"
    }
    else {
        Write-Output "Created branch '$branch' from '$base'."
    }
    Write-Output "Open it with: cd '$targetPath'"
}

function Invoke-GitWorkRemove {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitWorkRemoveHelp
        return
    }
    if (@($Arguments).Count -eq 0) {
        throw "a worktree path or branch is required. Run '$($script:CommandPrefix) work remove -h' for usage."
    }

    $selector = [string]$Arguments[0]
    $optionArgs = @()
    if (@($Arguments).Count -gt 1) {
        $optionArgs = [string[]]$Arguments[1..($Arguments.Count - 1)]
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $optionArgs `
        -ValueOptions @{} `
        -SwitchOptions @{ '--force' = 'Force'; '--yes' = 'Yes' }
    $force = $options.ContainsKey('Force')
    $yes = $options.ContainsKey('Yes')

    $root = Get-GitWorkCurrentRoot
    $entries = @(Get-GitCommandWorktrees $root)
    $entry = Find-GitWorkEntry -RepoRoot $root -Selector $selector

    if ($entries.Count -gt 0 -and $entry.FullPath -ieq $entries[0].FullPath) {
        throw "the main worktree cannot be removed: $($entry.Path)"
    }
    if ($entry.FullPath -ieq $root) {
        throw "the worktree containing the current directory cannot be removed: $($entry.Path)"
    }
    if (-not $entry.Exists) {
        throw "worktree path no longer exists: $($entry.Path). Run 'git work prune' to clean stale metadata."
    }

    $dirty = $false
    $changed = @()
    $status = Invoke-GitCommand -RepoRoot $entry.FullPath -Arguments @('status', '--porcelain=v1', '--untracked-files=all') -AllowFailure
    if ($status.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($status.Text)) {
        $dirty = $true
        $changed = @($status.Output | ForEach-Object { [string]$_ })
    }
    if ($dirty -and -not $force) {
        $preview = @($changed | Select-Object -First 8) -join "`n"
        throw "worktree is dirty; refusing to remove it.`n$preview`nRe-run with --force only if the changes can be discarded."
    }
    if ($entry.Locked -and -not $force) {
        throw "worktree is locked; unlock it first or use --force after verifying it is safe."
    }

    Write-Output "Worktree: $($entry.Path)"
    Write-Output "Branch:   $(if ($entry.Branch) { $entry.Branch } else { '(detached)' })"
    if ($dirty) {
        Write-Output 'WARNING: the worktree has uncommitted or untracked changes that will be discarded.'
    }
    if (-not $yes) {
        $approved = Read-GitCommandConfirmation "Remove this worktree? The branch will be kept. Type y to continue:"
        if (-not $approved) {
            Write-Output 'Cancelled.'
            return
        }
    }

    $gitArguments = @('worktree', 'remove')
    if ($force) {
        $gitArguments += '--force'
    }
    $gitArguments += @($entry.Path)
    $result = Invoke-GitCommand -RepoRoot $root -Arguments $gitArguments
    foreach ($line in @($result.Output)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-Output ([string]$line)
        }
    }
    Write-Output "Removed worktree: $($entry.Path)"
    if (-not [string]::IsNullOrWhiteSpace($entry.Branch)) {
        Write-Output "Branch '$($entry.Branch)' was kept."
    }
}

function Get-GitWorkPruneLines {
    param([Parameter(Mandatory = $true)]$Result)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($Result.Output)) {
        $value = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $lines.Add($value)
        }
    }
    foreach ($line in @(([string]$Result.Error) -split "`r?`n")) {
        $value = [string]$line
        if ($value -match '^(?:git\.exe\s*:\s*)?(Removing|Pruning)\b') {
            $value = $value -replace '^git\.exe\s*:\s*', ''
            $lines.Add($value.Trim())
        }
    }
    return [string[]]$lines
}
function Invoke-GitWorkPrune {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitWorkPruneHelp
        return
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{} `
        -SwitchOptions @{ '--apply' = 'Apply'; '--dry-run' = 'DryRun'; '--yes' = 'Yes' }
    if ($options.ContainsKey('Apply') -and $options.ContainsKey('DryRun')) {
        throw '--apply and --dry-run cannot be used together.'
    }

    $root = Get-GitWorkCurrentRoot
    $preview = Invoke-GitCommand -RepoRoot $root -Arguments @('worktree', 'prune', '--dry-run', '--verbose')
    $previewLines = @(Get-GitWorkPruneLines $preview)
    if ($previewLines.Count -eq 0) {
        Write-Output 'No stale worktree metadata found.'
        return
    }

    foreach ($line in $previewLines) {
        Write-Output ([string]$line)
    }

    if (-not $options.ContainsKey('Apply')) {
        Write-Output ''
        Write-Output 'Dry run only. Re-run with --apply to remove this stale metadata.'
        return
    }

    if (-not $options.ContainsKey('Yes')) {
        $approved = Read-GitCommandConfirmation 'Remove the stale worktree metadata shown above? Type y to continue:'
        if (-not $approved) {
            Write-Output 'Cancelled.'
            return
        }
    }

    $result = Invoke-GitCommand -RepoRoot $root -Arguments @('worktree', 'prune', '--verbose')
    foreach ($line in @(Get-GitWorkPruneLines $result)) {
        Write-Output ([string]$line)
    }
    Write-Output 'Stale worktree metadata pruned.'
}
