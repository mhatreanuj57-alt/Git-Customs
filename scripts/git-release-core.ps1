function Show-GitReleaseUsage {
    Write-Output 'Usage: git release [command] [options]'
    Write-Output ''
    Write-Output 'Inspect release state, create a local annotated tag, or publish a GitHub release.'
    Write-Output ''
    Write-Output 'Commands:'
    Write-Output '  status   Show the latest tag, suggested next version, and release state (default)'
    Write-Output '  tag      Create a local annotated version tag without pushing'
    Write-Output '  publish  Push the tag and create a GitHub release after confirmation'
    Write-Output ''
    Write-Output "Run '$($script:CommandPrefix) <command> -h' for command options."
}

function Show-GitReleaseStatusHelp {
    Write-Output 'Usage: git release status'
    Write-Output ''
    Write-Output 'Shows local tags, the suggested next version, branch sync state, and'
    Write-Output 'whether the latest tag has a GitHub release. Read-only.'
}

function Show-GitReleaseTagHelp {
    Write-Output 'Usage: git release tag <version> [--yes]'
    Write-Output ''
    Write-Output 'Creates an annotated tag such as v1.2.3 at HEAD. This command is local only;'
    Write-Output 'it never pushes. Use publish to push the tag and create a GitHub release.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --yes  Skip the interactive confirmation prompt'
}

function Show-GitReleasePublishHelp {
    Write-Output 'Usage: git release publish <version> [--title <title>] [--notes <text>] [--notes-file <path>] [--draft] [--prerelease] [--yes]'
    Write-Output ''
    Write-Output 'Publishes an existing local tag. The tag must point at HEAD, the worktree'
    Write-Output 'must be clean, and the current branch must match origin/<default-branch>.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --title <title>      Release title (default: the tag name)'
    Write-Output '  --notes <text>       Release notes text'
    Write-Output '  --notes-file <path>  Read release notes from a UTF-8 file'
    Write-Output '  --draft              Create the release as a draft'
    Write-Output '  --prerelease         Mark the release as a prerelease'
    Write-Output '  --yes                Skip the interactive confirmation prompt'
}

function Get-GitReleaseVersionArgument {
    param(
        [string[]]$Arguments,
        [string]$CommandName,
        [string[]]$ValueOptions = @()
    )

    $version = $null
    $remaining = New-Object 'System.Collections.Generic.List[string]'
    $items = @($Arguments)
    $index = 0
    while ($index -lt $items.Count) {
        $text = [string]$items[$index]
        if ($text.StartsWith('--')) {
            $remaining.Add($text)
            if (-not $text.Contains('=') -and $ValueOptions -contains $text) {
                if (($index + 1) -ge $items.Count) {
                    throw "option '$text' requires a value."
                }
                $next = [string]$items[$index + 1]
                if ($next -eq '--' -or $next.StartsWith('--')) {
                    throw "option '$text' requires a value."
                }
                $remaining.Add($next)
                $index += 2
                continue
            }
            $index++
            continue
        }
        if ($null -ne $version) {
            throw "unexpected argument '$text'; $CommandName accepts one version."
        }
        $version = $text
        $index++
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "$CommandName requires a version such as 1.2.3."
    }
    return [pscustomobject]@{
        Version = (ConvertTo-GitCommandVersion $version)
        Remaining = [string[]]$remaining.ToArray()
    }
}

function Get-GitReleaseLocalTag {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $exists = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('show-ref', '--verify', '--quiet', "refs/tags/$Tag") -AllowFailure
    if ($exists.ExitCode -ne 0) {
        return [pscustomobject]@{ Exists = $false; Commit = $null; Type = $null }
    }
    $commit = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('rev-list', '-n', '1', $Tag)
    $type = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('cat-file', '-t', "refs/tags/$Tag")
    return [pscustomobject]@{
        Exists = $true
        Commit = $commit.Text.Trim()
        Type   = $type.Text.Trim()
    }
}

function Test-GitReleaseNotFound {
    param([string]$Message)

    return ([string]$Message -match '(?i)(not found|HTTP 404|404 Not Found)')
}

function Get-GitReleaseRemoteTag {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $path = "repos/$($Context.FullName)/git/ref/tags/$Tag"
    $result = Invoke-GitCommandGh -Arguments @('api', $path) -AllowFailure
    if ($result.ExitCode -ne 0) {
        $message = (@($result.Output) + @($result.Error)) -join "`n"
        if (Test-GitReleaseNotFound $message) {
            return [pscustomobject]@{ Exists = $false; Commit = $null; Error = $null }
        }
        return [pscustomobject]@{
            Exists = $false
            Commit = $null
            Error  = (Format-ActionWorkflowFailure $result)
        }
    }
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return [pscustomobject]@{ Exists = $false; Commit = $null; Error = $null }
    }

    try {
        $payload = $result.Text | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            Exists = $false
            Commit = $null
            Error  = "the remote tag lookup returned invalid JSON."
        }
    }
    if ($null -eq $payload -or $null -eq $payload.object) {
        return [pscustomobject]@{
            Exists = $false
            Commit = $null
            Error  = "the remote tag lookup returned an unexpected response."
        }
    }

    $type = [string]$payload.object.type
    $commit = [string]$payload.object.sha
    if ($type -eq 'tag') {
        $tagResult = Invoke-GitCommandGh -Arguments @('api', "repos/$($Context.FullName)/git/tags/$commit") -AllowFailure
        if ($tagResult.ExitCode -ne 0) {
            return [pscustomobject]@{
                Exists = $false
                Commit = $null
                Error  = (Format-ActionWorkflowFailure $tagResult)
            }
        }
        try {
            $tagPayload = $tagResult.Text | ConvertFrom-Json
            $commit = [string]$tagPayload.object.sha
        }
        catch {
            return [pscustomobject]@{
                Exists = $false
                Commit = $null
                Error  = "the remote annotated tag lookup returned invalid JSON."
            }
        }
    }

    return [pscustomobject]@{
        Exists = $true
        Commit = $commit
        Error  = $null
    }
}

function Get-GitReleaseRemoteRelease {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $result = Invoke-GitCommandGh -Arguments @(
        'release', 'view', $Tag,
        '--repo', $Context.RepoSpec,
        '--json', 'tagName,url,isDraft,isPrerelease'
    ) -AllowFailure
    if ($result.ExitCode -ne 0) {
        $message = (@($result.Output) + @($result.Error)) -join "`n"
        if (Test-GitReleaseNotFound $message) {
            return [pscustomobject]@{ Exists = $false; Data = $null; Error = $null }
        }
        return [pscustomobject]@{
            Exists = $false
            Data   = $null
            Error  = (Format-ActionWorkflowFailure $result)
        }
    }
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return [pscustomobject]@{ Exists = $false; Data = $null; Error = $null }
    }
    try {
        return [pscustomobject]@{
            Exists = $true
            Data   = ($result.Text | ConvertFrom-Json)
            Error  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $false
            Data   = $null
            Error  = 'the release lookup returned invalid JSON.'
        }
    }
}

function Get-GitReleaseSuggestedVersion {
    param($Latest)

    if ($null -eq $Latest) {
        return '0.1.0'
    }
    if ($Latest.Stable) {
        return "$($Latest.Major).$($Latest.Minor).$($Latest.Patch + 1)"
    }
    return "$($Latest.Major).$($Latest.Minor).$($Latest.Patch)"
}

function Write-GitReleaseSyncState {
    param($Info, [string]$DefaultBranch)

    $remote = Get-GitCommandRemoteTrackingSha -RepoRoot $Info.RepoRoot -Branch $Info.Branch
    if ([string]::IsNullOrWhiteSpace($remote)) {
        Write-Output "Sync: not pushed to origin/$($Info.Branch)"
        return
    }
    if ($remote -eq $Info.Head) {
        Write-Output "Sync: in sync with origin/$($Info.Branch)"
        return
    }
    $counts = Invoke-GitCommand -RepoRoot $Info.RepoRoot -Arguments @('rev-list', '--left-right', '--count', "HEAD...refs/remotes/origin/$($Info.Branch)") -AllowFailure
    if ($counts.ExitCode -eq 0) {
        $parts = @($counts.Text.Trim() -split '\s+')
        if ($parts.Count -ge 2) {
            Write-Output "Sync: out of sync with origin/$($Info.Branch) (ahead $($parts[0]), behind $($parts[1]))"
            return
        }
    }
    Write-Output "Sync: out of sync with origin/$($Info.Branch)"
}

function Invoke-GitReleaseStatus {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitReleaseStatusHelp
        return
    }
    if (@($Arguments).Count -gt 0) {
        throw "status does not accept arguments. Run '$($script:CommandPrefix) status -h' for usage."
    }

    $context = Get-ActionWorkflowContext
    $info = Get-GitCommandRepoInfo -RepoRoot $context.RepoRoot
    $defaultBranch = Get-GitCommandDefaultBranch -RepoRoot $context.RepoRoot
    $latest = Get-GitCommandLatestVersion -RepoRoot $context.RepoRoot
    $suggested = Get-GitReleaseSuggestedVersion $latest

    Write-Output "Repository: $($context.RepoSpec)"
    Write-Output "Branch: $($info.Branch) (default: $defaultBranch)"
    Write-Output "Working tree: $(if ($info.IsDirty) { "dirty ($($info.ChangedPaths.Count) changed)" } else { 'clean' })"
    if ($info.Branch -ne $defaultBranch) {
        Write-Output "Warning: publish requires the default branch '$defaultBranch'."
    }
    Write-GitReleaseSyncState $info $defaultBranch
    if ($null -eq $latest) {
        Write-Output 'Latest tag: (none)'
    }
    else {
        Write-Output "Latest tag: $($latest.Tag)"
    }
    Write-Output "Suggested next version: $suggested"

    if ($null -eq $latest) {
        Write-Output 'Release: (no tags)'
        return
    }

    $remoteRelease = Get-GitReleaseRemoteRelease -Context $context -Tag $latest.Tag
    if ($remoteRelease.Exists) {
        $labels = @()
        if ($remoteRelease.Data.isDraft -eq $true) { $labels += 'draft' }
        if ($remoteRelease.Data.isPrerelease -eq $true) { $labels += 'prerelease' }
        $suffix = ''
        if ($labels.Count -gt 0) {
            $suffix = " [$($labels -join ', ')]"
        }
        Write-Output "Release: $($remoteRelease.Data.url)$suffix"
    }
    elseif ([string]::IsNullOrWhiteSpace($remoteRelease.Error)) {
        Write-Output 'Release: not published'
    }
    else {
        $reason = (@($remoteRelease.Error -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        Write-Output "Release: unknown ($reason)"
    }
}

function Invoke-GitReleaseTag {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitReleaseTagHelp
        return
    }
    $parsed = Get-GitReleaseVersionArgument -Arguments $Arguments -CommandName 'tag'
    $options = ConvertTo-ActionWorkflowOptions -Arguments $parsed.Remaining -ValueOptions @{} -SwitchOptions @{ '--yes' = 'Yes' }
    $version = $parsed.Version

    $repoRoot = Get-GitCommandRepoRoot
    $info = Get-GitCommandRepoInfo -RepoRoot $repoRoot
    if (-not $info.HasHead) {
        throw 'repository has no commits; create a commit before tagging a release.'
    }

    $existing = Get-GitReleaseLocalTag -RepoRoot $repoRoot -Tag $version.Tag
    if ($existing.Exists) {
        throw "tag '$($version.Tag)' already exists; choose a new version."
    }

    Write-Output "Tag: $($version.Tag)"
    Write-Output "Commit: $(Format-GitCommandShortSha $info.Head)"
    Write-Output 'This creates a local tag only; it does not push or publish.'
    if (-not $options.ContainsKey('Yes')) {
        $approved = Read-GitCommandConfirmation 'Create this tag? Type y to continue:'
        if (-not $approved) {
            Write-Output 'Cancelled.'
            return
        }
    }

    Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('tag', '-a', $version.Tag, '-m', "Release $($version.Tag)", $info.Head) | Out-Null
    Write-Output "Created annotated tag $($version.Tag) at $(Format-GitCommandShortSha $info.Head)."
    Write-Output "Run '$($script:CommandPrefix) publish $($version.Version)' to push it and create a GitHub release."
}

function Assert-GitReleasePublishState {
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$DefaultBranch
    )

    $localTag = Get-GitReleaseLocalTag -RepoRoot $Info.RepoRoot -Tag $Tag
    if (-not $localTag.Exists) {
        throw "local tag '$Tag' does not exist. Create it first with '$($script:CommandPrefix) tag <version>'."
    }
    if ($localTag.Commit -ne $Info.Head) {
        throw "tag '$Tag' points to $(Format-GitCommandShortSha $localTag.Commit), not HEAD $(Format-GitCommandShortSha $Info.Head); check out the tagged commit."
    }
    if ($Info.Detached) {
        throw 'repository is in a detached HEAD state; check out the default branch before publishing.'
    }
    Assert-GitCommandClean $Info
    if ($Info.Branch -ne $DefaultBranch) {
        throw "publish requires the default branch '$DefaultBranch'; current branch is '$($Info.Branch)'."
    }

    $remoteHead = Get-GitCommandRemoteTrackingSha -RepoRoot $Info.RepoRoot -Branch $Info.Branch
    if ([string]::IsNullOrWhiteSpace($remoteHead)) {
        throw "branch '$($Info.Branch)' is not pushed to origin; push it before publishing."
    }
    if ($remoteHead -ne $Info.Head) {
        throw "local branch '$($Info.Branch)' does not match origin/$($Info.Branch); push or pull before publishing."
    }

    return $localTag
}

function Invoke-GitReleasePublish {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitReleasePublishHelp
        return
    }
    $parsed = Get-GitReleaseVersionArgument -Arguments $Arguments -CommandName 'publish' -ValueOptions @('--title', '--notes', '--notes-file')
    $options = ConvertTo-ActionWorkflowOptions -Arguments $parsed.Remaining `
        -ValueOptions @{
            '--title' = 'Title'
            '--notes' = 'Notes'
            '--notes-file' = 'NotesFile'
        } `
        -SwitchOptions @{
            '--draft' = 'Draft'
            '--prerelease' = 'Prerelease'
            '--yes' = 'Yes'
        }
    $version = $parsed.Version

    if ($options.ContainsKey('Notes') -and $options.ContainsKey('NotesFile')) {
        throw '--notes and --notes-file cannot be used together.'
    }
    $title = $version.Tag
    if ($options.ContainsKey('Title')) {
        $title = ([string]$options['Title']).Trim()
        if ([string]::IsNullOrWhiteSpace($title) -or $title.Length -gt 256 -or $title -match '[\r\n]') {
            throw '--title must be a single line between 1 and 256 characters.'
        }
    }

    $notes = $null
    if ($options.ContainsKey('Notes')) {
        $notes = [string]$options['Notes']
    }
    elseif ($options.ContainsKey('NotesFile')) {
        $notesPath = [string]$options['NotesFile']
        if (-not (Test-Path -LiteralPath $notesPath -PathType Leaf)) {
            throw "notes file does not exist: $notesPath"
        }
        $notes = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $notesPath).ProviderPath)
    }
    if ($null -ne $notes -and $notes.Length -gt 125000) {
        throw 'release notes must be 125000 characters or fewer.'
    }

    $context = Get-ActionWorkflowContext
    $info = Get-GitCommandRepoInfo -RepoRoot $context.RepoRoot
    $defaultBranch = Get-GitCommandDefaultBranch -RepoRoot $context.RepoRoot
    $localTag = Assert-GitReleasePublishState -Info $info -Tag $version.Tag -DefaultBranch $defaultBranch

    $remoteTag = Get-GitReleaseRemoteTag -Context $context -Tag $version.Tag
    if (-not [string]::IsNullOrWhiteSpace($remoteTag.Error)) {
        throw "could not check remote tag '$($version.Tag)'.`n$($remoteTag.Error)"
    }
    if ($remoteTag.Exists -and $remoteTag.Commit -ne $info.Head) {
        throw "remote tag '$($version.Tag)' points to $(Format-GitCommandShortSha $remoteTag.Commit), not HEAD $(Format-GitCommandShortSha $info.Head)."
    }

    $remoteRelease = Get-GitReleaseRemoteRelease -Context $context -Tag $version.Tag
    if (-not [string]::IsNullOrWhiteSpace($remoteRelease.Error)) {
        throw "could not check the GitHub release for '$($version.Tag)'.`n$($remoteRelease.Error)"
    }
    if ($remoteRelease.Exists) {
        throw "a GitHub release already exists for '$($version.Tag)': $($remoteRelease.Data.url)"
    }

    $tagState = 'push tag to origin'
    if ($remoteTag.Exists) {
        $tagState = 'tag already exists at HEAD (no push needed)'
    }

    Write-Output "Repository: $($context.RepoSpec)"
    Write-Output "Release: $($version.Tag)"
    Write-Output "Title: $title"
    Write-Output "Tag: $tagState"
    if ($options.ContainsKey('Draft')) { Write-Output 'Draft: yes' }
    if ($options.ContainsKey('Prerelease')) { Write-Output 'Prerelease: yes' }
    if (-not $options.ContainsKey('Yes')) {
        $approved = Read-GitCommandConfirmation 'Publish this release? Type y to continue:'
        if (-not $approved) {
            Write-Output 'Cancelled.'
            return
        }
    }

    $pushedTag = $false
    if (-not $remoteTag.Exists) {
        Invoke-GitCommand -RepoRoot $context.RepoRoot -Arguments @('push', 'origin', "refs/tags/$($version.Tag)") | Out-Null
        $pushedTag = $true
    }

    $ghArguments = @(
        'release', 'create', $version.Tag,
        '--repo', $context.RepoSpec,
        '--verify-tag',
        "--title=$title"
    )
    if ($null -ne $notes) {
        $ghArguments += "--notes=$notes"
    }
    else {
        $ghArguments += '--generate-notes'
    }
    if ($options.ContainsKey('Draft')) { $ghArguments += '--draft' }
    if ($options.ContainsKey('Prerelease')) { $ghArguments += '--prerelease' }

    try {
        $result = Invoke-GitCommandGh -Arguments $ghArguments
    }
    catch {
        if ($pushedTag) {
            throw "tag '$($version.Tag)' was pushed, but creating the GitHub release failed; fix the issue and rerun publish.`n$($_.Exception.Message)"
        }
        throw "tag '$($version.Tag)' already exists remotely, but creating the GitHub release failed; fix the issue and rerun publish.`n$($_.Exception.Message)"
    }

    $url = (@($result.Output) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace([string]$url)) {
        $url = "(no URL returned; tag $($version.Tag) is at $($localTag.Commit))"
    }
    Write-Output "Release published: $url"
}
