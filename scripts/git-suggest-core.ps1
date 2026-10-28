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

function Get-GitDiffMessage {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Entry)

    $paths = @($Entry.Path)
    if ($Entry.OldPath) { $paths = @($Entry.OldPath, $Entry.Path) }
    $diffArgs = @('-C', $Context.RepoRoot, 'diff', '--binary', '--no-ext-diff', '--unified=0')
    if ($Context.HasHead) { $diffArgs += @('HEAD', '--') } else { $diffArgs += @('--') }
    $diffArgs += $paths
    $diff = Invoke-GitDetect $diffArgs
    $text = $diff.Output -join "`n"
    $numstatArgs = @('-C', $Context.RepoRoot, 'diff', '--numstat', '--no-ext-diff')
    if ($Context.HasHead) { $numstatArgs += @('HEAD', '--') } else { $numstatArgs += @('--') }
    $numstatArgs += $paths
    $numstat = (Invoke-GitDetect $numstatArgs).Output -join "`n"
    $isBinary = $numstat -match '^[-\t]+-' -or $text -match '^Binary files '

    $filePath = Join-Path $Context.RepoRoot $Entry.Path
    $signature = $text
    if (Test-Path -LiteralPath $filePath -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $isBinary = $isBinary -or ($bytes -contains 0)
        $signature = $Entry.Path + [string][char]0 + [string]$Entry.OldPath + [string][char]0 + [Convert]::ToBase64String($bytes)
        if ($Entry.IsUntracked -and -not $isBinary) { $text = (([System.IO.File]::ReadAllText($filePath) -split "`r?`n" | ForEach-Object { "+$_" }) -join "`n") }
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [string]::Join('', [string[]]@($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($signature)) | ForEach-Object { $_.ToString('x2') })) }
    finally { $hash.Dispose() }
    $Entry | Add-Member -NotePropertyName DiffHash -NotePropertyValue $fingerprint -Force

    $name = [System.IO.Path]::GetFileName($Entry.Path)
    if ($name -match '(?i)(secret|credential|token|password|\.env)') { $name = 'configuration' }
    if ($isBinary) {
        if ($Entry.IsDeleted) { return "chore: remove binary asset $name" }
        if ($Entry.IsUntracked -or $Entry.X -eq 'A') { return "chore: add binary asset $name" }
        return "chore: update binary asset $name"
    }

    $changes = @($text -split "`r?`n" | Where-Object { $_ -match '^[+-]' -and $_ -notmatch '^(\+\+\+|---)' }) -join "`n"
    if ($changes -match '(?i)(redirect|returnUrl|callbackUrl|loginRedirect)') { return 'fix: correct login redirect' }
    if ($changes -match '(?i)(responsive|@media|breakpoint)' -and $changes -match '(?i)(nav|menu|header)') { return 'feat: add responsive navigation' }
    if ($changes -match '(?i)(aria-|\brole=|keyboard|focus-visible)') { return 'fix: improve keyboard accessibility' }
    if ($changes -match '(?i)(validation|validate|invalid)') { return 'fix: improve input validation' }

    $symbol = $null
    foreach ($pattern in @('(?i)(?:function|def|class)\s+([A-Za-z][A-Za-z0-9_-]{1,40})', '(?i)(?:const|let|var)\s+([A-Za-z][A-Za-z0-9_]{1,40})', '(?i)\.([A-Za-z][A-Za-z0-9_-]{1,40})\s*\{')) {
        $match = [regex]::Match($changes, $pattern)
        if ($match.Success -and $match.Groups[1].Value -notmatch '(?i)(secret|credential|token|password)') { $symbol = $match.Groups[1].Value; break }
    }
    if ($symbol) {
        if ($Entry.IsDeleted) { return "refactor: remove $symbol" }
        if ($Entry.IsUntracked -or $Entry.X -eq 'A') { return "feat: add $symbol" }
        return "refactor: update $symbol behavior"
    }
    if ($Entry.IsDeleted) { return "refactor: remove $name" }
    if ($Entry.IsUntracked -or $Entry.X -eq 'A') { return "chore: add $name" }
    return "chore: update $name content"
}

function Get-GitCombinedMessage {
    param([Parameter(Mandatory = $true)][object[]]$Suggestions)
    $types = @($Suggestions | ForEach-Object { if ($_.Message -match '^([a-z]+):') { $Matches[1] } } | Select-Object -Unique)
    if ($types.Count -eq 1) { $type = $types[0] } elseif ($types -contains 'feat') { $type = 'feat' } elseif ($types -contains 'fix') { $type = 'fix' } else { $type = 'chore' }
    $uniqueSubjects = @($Suggestions | ForEach-Object { $_.Message -replace '^[a-z]+:\s*', '' } | Select-Object -Unique)
    $subjects = @($uniqueSubjects | Select-Object -First 3)
    if ($uniqueSubjects.Count -gt 3) { $subjects += 'and related changes' }
    return ('{0}: {1}' -f $type, ($subjects -join '; '))
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

        if ($isRename) {
            $kind = 'Rename'
        }
        elseif ($isCopy) {
            $kind = 'Copy'
        }
        elseif ($isDeleted) {
            $kind = 'Delete'
        }
        elseif ($isUntracked -or $x -eq 'A') {
            $kind = 'Add'
        }
        else {
            $kind = 'Update'
        }
        $entry | Add-Member -NotePropertyName IsUntracked -NotePropertyValue $isUntracked -Force
        $entry | Add-Member -NotePropertyName IsDeleted -NotePropertyValue $isDeleted -Force
        $entry | Add-Member -NotePropertyName X -NotePropertyValue $x -Force
        $message = Get-GitDiffMessage $Context $entry
        if ($isRename) { $message = "refactor: rename $oldPath to $path" }
        elseif ($isCopy) { $message = "feat: copy $oldPath to $path" }

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
            DiffHash            = $entry.DiffHash
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
