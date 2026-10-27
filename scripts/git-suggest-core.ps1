$ErrorActionPreference = 'Continue'

function Invoke-GitDetect {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & git --no-optional-locks @Arguments 2>$null
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = [string[]]@($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-GitAction {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & git @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = [string[]]@($output | ForEach-Object { [string]$_ })
            Error    = $stderr
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function Format-PushBranch {
    param([Parameter(Mandatory = $true)][string]$Branch)

    if ($Branch -match '^[A-Za-z0-9._/-]+$' -and -not $Branch.StartsWith('-')) {
        return $Branch
    }

    return ConvertTo-PowerShellLiteral $Branch
}

function Get-GitRepositoryContext {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or is not available on PATH.'
    }

    $repoCheck = Invoke-GitDetect @('rev-parse', '--is-inside-work-tree')
    if ($repoCheck.ExitCode -ne 0 -or (($repoCheck.Output -join '').Trim() -ne 'true')) {
        throw 'not inside a Git working tree.'
    }

    $rootResult = Invoke-GitDetect @('rev-parse', '--show-toplevel')
    if ($rootResult.ExitCode -ne 0) {
        throw 'could not determine the repository root.'
    }

    $repoRoot = ($rootResult.Output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'could not determine the repository root.'
    }

    $leafPath = ($repoRoot -replace '/', '\').TrimEnd([char]'\')
    $repoName = Split-Path -Leaf $leafPath
    if ([string]::IsNullOrWhiteSpace($repoName)) {
        $repoName = $repoRoot
    }

    $originResult = Invoke-GitDetect @('-C', $repoRoot, 'remote', 'get-url', 'origin')
    $originUrl = ($originResult.Output -join '').Trim()
    if ($originResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) {
        throw "repository `"$repoName`" has no 'origin' remote configured."
    }

    $branchResult = Invoke-GitDetect @('-C', $repoRoot, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    $branch = ($branchResult.Output -join '').Trim()
    if ($branchResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw "repository `"$repoName`" is in a detached HEAD state; check out a branch first."
    }

    $headProbe = Invoke-GitDetect @('-C', $repoRoot, 'rev-parse', '--verify', '--quiet', 'HEAD')
    $hasHead = ($headProbe.ExitCode -eq 0)

    [pscustomobject]@{
        RepoRoot   = $repoRoot
        RepoName   = $repoName
        OriginUrl  = $originUrl
        Branch     = $branch
        HasHead    = $hasHead
        CountCache = @{}
    }
}

function Get-GitPendingChanges {
    param([Parameter(Mandatory = $true)]$Context)

    $statusResult = Invoke-GitDetect @('-C', $Context.RepoRoot, 'status', '--porcelain=v1', '-z', '-uall')
    if ($statusResult.ExitCode -ne 0) {
        throw 'failed to read the repository status.'
    }

    $rawStatus = [string]::Join("`n", $statusResult.Output)
    $records = @($rawStatus -split ([string][char]0))
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $hasConflicts = $false

    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        if ([string]::IsNullOrEmpty($record) -or $record.Length -lt 4) {
            continue
        }

        $x = $record.Substring(0, 1)
        $y = $record.Substring(1, 1)
        if ($x -eq '!' -and $y -eq '!') {
            continue
        }

        $path = $record.Substring(3)
        $oldPath = $null

        if ($x -eq 'R' -or $x -eq 'C') {
            $i++
            if ($i -lt $records.Count) {
                $candidate = $records[$i]
                if (-not [string]::IsNullOrEmpty($candidate)) {
                    $oldPath = $candidate
                }
            }
        }

        $unmerged = @('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU') -contains ($x + $y)
        if ($unmerged) {
            $hasConflicts = $true
        }

        $entries.Add([pscustomobject]@{
            X        = $x
            Y        = $y
            Path     = $path
            OldPath  = $oldPath
            Unmerged = $unmerged
        })
    }

    if ($hasConflicts) {
        throw 'the repository has unresolved merge conflicts; resolve them before using git suggest or git autopush.'
    }

    return [object[]]$entries.ToArray()
}

function Get-GitPriorCommitCount {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not $Context.HasHead) {
        return 0
    }

    if ($Context.CountCache.ContainsKey($Path)) {
        return $Context.CountCache[$Path]
    }

    $result = Invoke-GitDetect @(
        '--literal-pathspecs',
        '-C', $Context.RepoRoot,
        'log', '--follow', '--format=%H', '--', $Path
    )
    $count = 0

    if ($result.ExitCode -eq 0) {
        $count = @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    }

    $Context.CountCache[$Path] = $count
    return $count
}

function Get-GitSuggestionPlan {
    param([Parameter(Mandatory = $true)]$Context)

    $entries = Get-GitPendingChanges $Context
    $suggestions = New-Object 'System.Collections.Generic.List[object]'
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $addedCount = 0
    $modifiedCount = 0
    $deletedCount = 0
    $stagedCount = 0
    $untrackedCount = 0

    foreach ($entry in $entries) {
        $x = $entry.X
        $y = $entry.Y
        $path = $entry.Path
        $oldPath = $entry.OldPath

        $isUntracked = ($x -eq '?' -and $y -eq '?')
        $isDeleted = ($x -eq 'D' -or $y -eq 'D')
        $isRename = ($x -eq 'R' -and -not [string]::IsNullOrEmpty($oldPath))
        $isCopy = ($x -eq 'C' -and -not [string]::IsNullOrEmpty($oldPath))

        if ($isUntracked) {
            $untrackedCount++
        }
        elseif ($isRename -or $isCopy) {
            $modifiedCount++
        }
        elseif ($isDeleted) {
            $deletedCount++
        }
        elseif ($x -eq 'A') {
            $addedCount++
        }
        else {
            $modifiedCount++
        }

        if ($x -ne ' ' -and $x -ne '?') {
            $stagedCount++
        }

        $needsAdd = $isUntracked -or ($y -ne ' ')
        if ($x -eq 'A' -and $y -eq 'D') {
            $needsAdd = $false
        }

        if ($isRename -or $isCopy) {
            $countPath = $oldPath
        }
        else {
            $countPath = $path
        }

        $nextCount = (Get-GitPriorCommitCount $Context $countPath) + 1

        if ($isRename) {
            $kind = 'Rename'
            $message = "Rename $oldPath -> $path (file commit #$nextCount)"
        }
        elseif ($isCopy) {
            $kind = 'Copy'
            $message = "Copy $oldPath -> $path (file commit #$nextCount)"
        }
        elseif ($isDeleted) {
            $kind = 'Delete'
            $message = "Delete $path (file commit #$nextCount)"
        }
        elseif ($isUntracked -or $x -eq 'A') {
            $kind = 'Add'
            $message = "Add $path (file commit #$nextCount)"
        }
        else {
            $kind = 'Update'
            $message = "Update $path (file commit #$nextCount)"
        }

        if ($isRename) {
            $commitPaths = @($oldPath, $path)
        }
        else {
            $commitPaths = @($path)
        }

        $key = ($x + $y + [string][char]0 + [string]$oldPath + [string][char]0 + $path)
        if (-not $seenKeys.Add($key)) {
            throw "duplicate pending change detected for '$path'."
        }

        $globalArguments = @('--literal-pathspecs', '-C', $Context.RepoRoot)
        $addArguments = $null
        $displayAddCommand = $null

        if ($needsAdd) {
            if ($isDeleted) {
                $addArguments = $globalArguments + @('add', '-A', '--', $path)
                $displayAddCommand = 'git add -A -- ' + (ConvertTo-PowerShellLiteral $path)
            }
            else {
                $addArguments = $globalArguments + @('add', '--', $path)
                $displayAddCommand = 'git add -- ' + (ConvertTo-PowerShellLiteral $path)
            }
        }

        $commitArguments = $globalArguments + @('commit', '-m', $message, '--') + $commitPaths
        $quotedMessage = ConvertTo-PowerShellLiteral $message
        $quotedPaths = ($commitPaths | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ' '
        $displayCommitCommand = "git commit -m $quotedMessage -- $quotedPaths"

        $suggestions.Add([pscustomobject]@{
            Key                 = $key
            X                   = $x
            Y                   = $y
            Path                = $path
            OldPath             = $oldPath
            Kind                = $kind
            IsUntracked         = $isUntracked
            IsDeleted           = $isDeleted
            IsRename            = $isRename
            IsCopy              = $isCopy
            NeedsAdd            = $needsAdd
            AddArguments        = $addArguments
            CommitPaths         = [string[]]$commitPaths
            CommitArguments     = [string[]]$commitArguments
            Message             = $message
            NextCount           = $nextCount
            DisplayAddCommand   = $displayAddCommand
            DisplayCommitCommand = $displayCommitCommand
        })
    }

    [pscustomobject]@{
        Entries        = [object[]]$entries
        Suggestions    = [object[]]$suggestions.ToArray()
        AddedCount     = $addedCount
        ModifiedCount  = $modifiedCount
        DeletedCount   = $deletedCount
        StagedCount    = $stagedCount
        UntrackedCount = $untrackedCount
    }
}
