$ErrorActionPreference = 'Continue'

$env:GH_PAGER = 'cat'
$env:GH_PROMPT_DISABLED = '1'
$env:GH_NO_UPDATE_NOTIFIER = '1'
$env:NO_COLOR = '1'

function Invoke-GitCommand {
    param(
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $stderrFile = [System.IO.Path]::GetTempFileName()
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
            $output = & git --no-optional-locks @Arguments 2> $stderrFile
        }
        else {
            $output = & git -C $RepoRoot --no-optional-locks @Arguments 2> $stderrFile
        }
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }
        $lines = [string[]]@($output | ForEach-Object { [string]$_ })

        if ($exitCode -ne 0 -and -not $AllowFailure) {
            $details = (@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) + @($stderr.Trim())) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (@($details).Count -eq 0) {
                $details = @("git exited with code $exitCode.")
            }
            throw (($details -join "`n").Trim())
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $lines
            Error    = $stderr
            Text     = (($lines -join "`n").TrimEnd())
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GitCommandGh {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $stderrFile = [System.IO.Path]::GetTempFileName()
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & gh @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }
        $lines = [string[]]@($output | ForEach-Object { [string]$_ })

        if ($exitCode -ne 0 -and -not $AllowFailure) {
            $details = (@($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) + @($stderr.Trim())) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (@($details).Count -eq 0) {
                $details = @("gh exited with code $exitCode.")
            }
            throw (($details -join "`n").Trim())
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $lines
            Error    = $stderr
            Text     = (($lines -join "`n").TrimEnd())
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Read-GitCommandGhJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $result = Invoke-GitCommandGh -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }
    try {
        return ($result.Text | ConvertFrom-Json)
    }
    catch {
        throw "$Description returned invalid JSON."
    }
}

function Read-GitCommandConfirmation {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    Write-Host $Prompt
    $answer = [Console]::In.ReadLine()
    if ($null -eq $answer) {
        throw 'confirmation is required; run the command interactively and answer y to continue.'
    }
    return ($answer.Trim() -match '^(?i:y|yes)$')
}

function Get-GitCommandRepoRoot {
    param([switch]$AllowMissing)

    $result = Invoke-GitCommand -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Text.Trim() -ne 'true') {
        if ($AllowMissing) {
            return $null
        }
        throw 'not inside a Git working tree.'
    }

    $root = Invoke-GitCommand -Arguments @('rev-parse', '--show-toplevel')
    $value = $root.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'could not determine the repository root.'
    }
    return $value
}

function Get-GitCommandChangedPaths {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($result.Output)) {
        $text = [string]$line
        if ($text.Length -le 3) {
            continue
        }
        $path = $text.Substring(3).Trim()
        if ($path.StartsWith('"') -and $path.EndsWith('"') -and $path.Length -ge 2) {
            $path = $path.Substring(1, $path.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $paths.Add($path.Replace('\', '/'))
        }
    }
    return [object[]]$paths.ToArray()
}

function Get-GitCommandRepoInfo {
    param([string]$RepoRoot)

    $root = $RepoRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-GitCommandRepoRoot
    }

    $branchResult = Invoke-GitCommand -RepoRoot $root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowFailure
    $branch = $branchResult.Text.Trim()
    $detached = ($branchResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($branch))

    $head = ''
    $headResult = Invoke-GitCommand -RepoRoot $root -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD') -AllowFailure
    if ($headResult.ExitCode -eq 0) {
        $head = $headResult.Text.Trim()
    }

    $origin = ''
    $originResult = Invoke-GitCommand -RepoRoot $root -Arguments @('remote', 'get-url', 'origin') -AllowFailure
    if ($originResult.ExitCode -eq 0) {
        $origin = $originResult.Text.Trim()
    }

    $upstream = ''
    $upstreamResult = Invoke-GitCommand -RepoRoot $root -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -AllowFailure
    if ($upstreamResult.ExitCode -eq 0) {
        $upstream = $upstreamResult.Text.Trim()
    }

    $ahead = 0
    $behind = 0
    if (-not [string]::IsNullOrWhiteSpace($upstream)) {
        $countResult = Invoke-GitCommand -RepoRoot $root -Arguments @('rev-list', '--left-right', '--count', "HEAD...$upstream") -AllowFailure
        if ($countResult.ExitCode -eq 0) {
            $parts = @($countResult.Text.Trim() -split '\s+')
            if ($parts.Count -ge 2) {
                [void][int]::TryParse($parts[0], [ref]$ahead)
                [void][int]::TryParse($parts[1], [ref]$behind)
            }
        }
    }

    $paths = @(Get-GitCommandChangedPaths $root)
    $defaultBranch = $null
    $defaultResult = Invoke-GitCommand -RepoRoot $root -Arguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') -AllowFailure
    if ($defaultResult.ExitCode -eq 0) {
        $defaultBranch = $defaultResult.Text.Trim()
        if ($defaultBranch -match '^origin/(.+)$') {
            $defaultBranch = $Matches[1]
        }
    }

    [pscustomobject]@{
        RepoRoot      = $root
        Branch        = $branch
        Detached      = $detached
        Head          = $head
        HasHead       = (-not [string]::IsNullOrWhiteSpace($head))
        OriginUrl     = $origin
        HasOrigin     = (-not [string]::IsNullOrWhiteSpace($origin))
        Upstream      = $upstream
        HasUpstream   = (-not [string]::IsNullOrWhiteSpace($upstream))
        Ahead         = $ahead
        Behind        = $behind
        ChangedPaths  = $paths
        IsDirty       = ($paths.Count -gt 0)
        DefaultBranch = $defaultBranch
    }
}

function Get-GitCommandWorktrees {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('worktree', 'list', '--porcelain')
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $current = $null

    foreach ($line in @($result.Output)) {
        $text = [string]$line
        if ($text.StartsWith('worktree ')) {
            if ($null -ne $current) {
                $entries.Add($current)
            }
            $current = [ordered]@{
                Path     = $text.Substring(9)
                Head     = ''
                Branch   = ''
                Bare     = $false
                Detached = $false
                Locked   = $false
                Prunable = $false
            }
            continue
        }
        if ($null -eq $current) {
            continue
        }
        if ($text.StartsWith('HEAD ')) {
            $current.Head = $text.Substring(5)
        }
        elseif ($text.StartsWith('branch ')) {
            $value = $text.Substring(7)
            if ($value.StartsWith('refs/heads/')) {
                $value = $value.Substring(11)
            }
            $current.Branch = $value
        }
        elseif ($text -eq 'bare') {
            $current.Bare = $true
        }
        elseif ($text -eq 'detached') {
            $current.Detached = $true
        }
        elseif ($text.StartsWith('locked')) {
            $current.Locked = $true
        }
        elseif ($text.StartsWith('prunable')) {
            $current.Prunable = $true
        }
    }
    if ($null -ne $current) {
        $entries.Add($current)
    }

    $resultEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $entries) {
        $fullPath = $entry.Path
        try {
            $fullPath = [System.IO.Path]::GetFullPath($entry.Path)
        }
        catch {
        }
        $resultEntries.Add([pscustomobject]@{
            Path     = $entry.Path
            FullPath = $fullPath
            Head     = $entry.Head
            Branch   = $entry.Branch
            Bare     = [bool]$entry.Bare
            Detached = [bool]$entry.Detached
            Locked   = [bool]$entry.Locked
            Prunable = [bool]$entry.Prunable
            Exists   = (Test-Path -LiteralPath $entry.Path -PathType Container)
        })
    }
    return [object[]]$resultEntries.ToArray()
}

function ConvertTo-GitCommandSafeSlug {
    param([Parameter(Mandatory = $true)][string]$Value)

    $slug = ($Value -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.', ' ')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'worktree'
    }
    if ($slug.Length -gt 80) {
        $slug = $slug.Substring(0, 80).TrimEnd('-', '.', ' ')
    }
    if ($slug -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
        $slug += '-wt'
    }
    return $slug
}

function Assert-GitCommandBranchName {
    param([Parameter(Mandatory = $true)][string]$Branch)

    $value = $Branch.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'branch name is empty.'
    }
    if ($value.StartsWith('-') -or $value -match '[\x00-\x20~^:?*\[\\]' -or $value.Contains('..') -or $value.EndsWith('.')) {
        throw "branch name '$Branch' is not valid."
    }
    $result = Invoke-GitCommand -Arguments @('check-ref-format', '--branch', $value) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "branch name '$Branch' is not valid."
    }
    return $value
}

function Get-GitCommandDefaultBranch {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $remoteHead = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') -AllowFailure
    if ($remoteHead.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteHead.Text)) {
        $value = $remoteHead.Text.Trim()
        if ($value -match '^origin/(.+)$') {
            return $Matches[1]
        }
        return $value
    }

    foreach ($candidate in @('main', 'master')) {
        $exists = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/remotes/origin/$candidate") -AllowFailure
        if ($exists.ExitCode -eq 0) {
            return $candidate
        }
    }

    foreach ($candidate in @('main', 'master')) {
        $exists = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$candidate") -AllowFailure
        if ($exists.ExitCode -eq 0) {
            return $candidate
        }
    }

    $configured = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('config', '--get', 'init.defaultBranch') -AllowFailure
    if ($configured.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($configured.Text)) {
        return $configured.Text.Trim()
    }
    return 'main'
}

function ConvertTo-GitCommandVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    $value = $Version.Trim()
    if ($value.StartsWith('v')) {
        $value = $value.Substring(1)
    }
    if ($value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw "version '$Version' is not a valid semantic version such as 1.2.3."
    }

    $numberPart = ($value -split '[+-]', 2)[0]
    $parts = @($numberPart -split '\.')
    [pscustomobject]@{
        Version = $value
        Tag     = "v$value"
        Major   = [int]$parts[0]
        Minor   = [int]$parts[1]
        Patch   = [int]$parts[2]
        Stable  = ($value -notmatch '[-+]')
    }
}

function Get-GitCommandLatestVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('tag', '--list', '--sort=-v:refname') -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }
    foreach ($tag in @($result.Output)) {
        $name = ([string]$tag).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        try {
            return (ConvertTo-GitCommandVersion $name)
        }
        catch {
        }
    }
    return $null
}

function Test-GitCommandAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Ancestor,
        [Parameter(Mandatory = $true)][string]$Descendant
    )

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure
    return ($result.ExitCode -eq 0)
}

function Assert-GitCommandClean {
    param([Parameter(Mandatory = $true)]$Info)

    if ($Info.IsDirty) {
        $shown = @($Info.ChangedPaths | Select-Object -First 10)
        $details = $shown -join ', '
        if ($Info.ChangedPaths.Count -gt $shown.Count) {
            $details += ", ... ($($Info.ChangedPaths.Count) total)"
        }
        throw "the worktree must be clean before this operation; changed paths: $details"
    }
}

function Format-GitCommandShortSha {
    param([string]$Sha)

    $value = [string]$Sha
    if ($value.Length -gt 12) {
        return $value.Substring(0, 12)
    }
    return $value
}

function Format-GitCommandTime {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return '-'
    }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    }
    return $Value
}

function Get-GitCommandRemoteTrackingSha {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Branch") -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }
    return $result.Text.Trim()
}
