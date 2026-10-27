[CmdletBinding()]
param([switch]$Keep)

. (Join-Path $PSScriptRoot 'lib\TestHelpers.ps1')
Initialize-TestEnvironment -TestScriptRoot $PSScriptRoot -Suite 'release' -Keep:$Keep

function New-EmptyRepo {
    param([Parameter(Mandatory = $true)][string]$Name)
    $repo = New-TestDirectory $Name
    Invoke-SetupGit $repo @('init', '-b', 'main') | Out-Null
    Invoke-SetupGit $repo @('config', 'user.name', 'Test User') | Out-Null
    Invoke-SetupGit $repo @('config', 'user.email', 'test@example.com') | Out-Null
    return $repo
}

function New-ReleaseRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Tag = ''
    )

    $repo = New-TestRepo -Path (Join-Path $script:SuiteRoot $Name)
    $bare = New-TestDirectory "remote-$Name.git"
    & git init --bare $bare | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'could not initialize the test bare remote.'
    }
    Invoke-SetupGit $repo @('config', "url.$bare.pushInsteadOf", 'https://github.com/example/demo.git') | Out-Null
    $head = (& git -C $repo rev-parse HEAD).Trim()
    Set-OriginTracking -Repo $repo -Branch 'main' -Sha $head
    New-TestState -Name $Name | Out-Null
    Set-StateText 'defaultBranch' 'main'
    Set-StateText 'release-create-url' 'https://github.com/example/demo/releases/tag/v1.2.3'
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        Invoke-SetupGit $repo @('tag', '-a', $Tag, '-m', "Release $Tag", $head) | Out-Null
    }

    return [pscustomobject]@{
        Repo = $repo
        Bare = $bare
        Head = $head
    }
}

function Get-BareTag {
    param($Release, [string]$Tag)
    return (Invoke-TestGit -Repo $Release.Repo -Arguments @('-C', $Release.Bare, 'rev-parse', '--verify', '--quiet', "refs/tags/$Tag^{}"))
}

try {
    Test-Case 'release help is available' {
        $release = New-ReleaseRepo -Name 'help'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', '-h')
        Assert-ExitCode $result 0 'release -h'
        Assert-Match $result.Text 'Usage: git release' 'release usage'
        Assert-Match $result.Text '(?s)status.*tag.*publish' 'release commands'
    }

    Test-Case 'release help is available for every command' {
        $release = New-ReleaseRepo -Name 'help-commands'
        foreach ($command in @('status', 'tag', 'publish')) {
            $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', $command, '-h')
            Assert-ExitCode $result 0 "release $command -h"
            Assert-Match $result.Text "Usage: git release $command" "$command usage"
        }
    }

    Test-Case 'release status suggests 0.1.0 before the first tag' {
        $release = New-ReleaseRepo -Name 'status-empty'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'empty status'
        Assert-Match $result.Text 'Branch: main \(default: main\)' 'default branch'
        Assert-Match $result.Text 'Working tree: clean' 'clean worktree'
        Assert-Match $result.Text 'Sync: in sync with origin/main' 'sync state'
        Assert-Match $result.Text 'Latest tag: \(none\)' 'no latest tag'
        Assert-Match $result.Text 'Suggested next version: 0.1.0' 'first version'
        Assert-Match $result.Text 'Release: \(no tags\)' 'no releases'
    }

    Test-Case 'release status is the default command' {
        $release = New-ReleaseRepo -Name 'status-default'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release')
        Assert-ExitCode $result 0 'default status'
        Assert-Match $result.Text 'Suggested next version: 0.1.0' 'default status suggestion'
    }

    Test-Case 'release status suggests the next stable version' {
        $release = New-ReleaseRepo -Name 'status-stable' -Tag 'v1.2.3'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'stable status'
        Assert-Match $result.Text 'Latest tag: v1.2.3' 'latest stable tag'
        Assert-Match $result.Text 'Suggested next version: 1.2.4' 'next patch version'
        Assert-Match $result.Text 'Release: not published' 'unpublished release'
    }

    Test-Case 'release status suggests the stable base for a prerelease' {
        $release = New-ReleaseRepo -Name 'status-prerelease-tag' -Tag 'v2.0.0-rc.1'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'prerelease status'
        Assert-Match $result.Text 'Latest tag: v2.0.0-rc.1' 'latest prerelease tag'
        Assert-Match $result.Text 'Suggested next version: 2.0.0' 'stable suggestion'
    }

    Test-Case 'release status labels draft and prerelease releases' {
        $release = New-ReleaseRepo -Name 'status-release-labels' -Tag 'v1.2.3'
        Set-StateJson 'release.json' ([pscustomobject]@{
            tagName      = 'v1.2.3'
            url          = 'https://github.com/example/demo/releases/tag/v1.2.3'
            isDraft      = $true
            isPrerelease = $true
        })
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'release labels status'
        Assert-Match $result.Text 'Release: https://github.com/example/demo/releases/tag/v1.2.3 \[draft, prerelease\]' 'release labels'
    }

    Test-Case 'release status reports dirty worktrees and non-default branches' {
        $release = New-ReleaseRepo -Name 'status-dirty-feature' -Tag 'v1.2.3'
        Invoke-SetupGit $release.Repo @('checkout', '-b', 'feature') | Out-Null
        Set-Content -LiteralPath (Join-Path $release.Repo 'dirty.txt') -Value 'dirty' -Encoding utf8
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'dirty feature status'
        Assert-Match $result.Text 'Branch: feature \(default: main\)' 'feature branch'
        Assert-Match $result.Text 'Warning: publish requires the default branch' 'branch warning'
        Assert-Match $result.Text 'Working tree: dirty \(1 changed\)' 'dirty count'
        Assert-Match $result.Text 'Sync: not pushed to origin/feature' 'feature sync'
    }

    Test-Case 'release status reports out-of-sync branches' {
        $release = New-ReleaseRepo -Name 'status-out-of-sync'
        Add-TestCommit -Repo $release.Repo -FileName 'ahead.txt' -Content 'ahead' | Out-Null
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'out of sync status'
        Assert-Match $result.Text 'Sync: out of sync with origin/main \(ahead 1, behind 0\)' 'out of sync counts'
    }

    Test-Case 'release status survives a release lookup error' {
        $release = New-ReleaseRepo -Name 'status-release-error' -Tag 'v1.2.3'
        Set-StateFailure @('release-view')
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status')
        Assert-ExitCode $result 0 'release lookup error status'
        Assert-Match $result.Text 'Release: unknown \(' 'unknown release label'
        Assert-Match $result.Text 'rate limit' 'lookup error reason'
    }

    Test-Case 'release status rejects arguments' {
        $release = New-ReleaseRepo -Name 'status-arguments'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'status', 'extra')
        Assert-ExitCode $result 1 'status argument'
        Assert-Match $result.Error 'does not accept arguments' 'status argument error'
    }

    Test-Case 'release tag requires confirmation and creates an annotated tag' {
        $release = New-ReleaseRepo -Name 'tag-confirm'
        $cancelled = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', '1.2.3') -InputText 'n'
        Assert-ExitCode $cancelled 0 'cancelled tag'
        Assert-Match $cancelled.Text 'Cancelled' 'tag cancel'
        $missing = Invoke-TestGit -Repo $release.Repo -Arguments @('show-ref', '--verify', '--quiet', 'refs/tags/v1.2.3')
        Assert-ExitCode $missing 1 'tag after cancel'

        $created = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', '1.2.3', '--yes')
        Assert-ExitCode $created 0 'created tag'
        Assert-Match $created.Text 'Created annotated tag v1.2.3' 'tag success'
        $type = Invoke-TestGit -Repo $release.Repo -Arguments @('cat-file', '-t', 'refs/tags/v1.2.3')
        Assert-ExitCode $type 0 'tag type'
        Assert-Equal 'tag' $type.Text.Trim() 'annotated tag type'
        $peeled = Invoke-TestGit -Repo $release.Repo -Arguments @('rev-parse', 'v1.2.3^{}')
        Assert-Equal $release.Head $peeled.Text.Trim() 'tag target'
    }

    Test-Case 'release tag accepts a v prefix and rejects duplicates' {
        $release = New-ReleaseRepo -Name 'tag-v-prefix'
        $created = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', 'v1.2.3', '--yes')
        Assert-ExitCode $created 0 'v prefix tag'
        Assert-Match $created.Text 'Created annotated tag v1.2.3' 'v prefix tag name'

        $duplicate = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', '1.2.3', '--yes')
        Assert-ExitCode $duplicate 1 'duplicate tag'
        Assert-Match $duplicate.Error 'already exists' 'duplicate tag error'
    }

    Test-Case 'release tag validates versions and repository state' {
        $release = New-ReleaseRepo -Name 'tag-validation'
        $invalid = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', 'not-a-version', '--yes')
        Assert-ExitCode $invalid 1 'invalid version'
        Assert-Match $invalid.Error 'not a valid semantic version' 'invalid version error'

        $missing = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', '--yes')
        Assert-ExitCode $missing 1 'missing version'
        Assert-Match $missing.Error 'requires a version' 'missing version error'

        $extra = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'tag', '1.2.3', '1.2.4', '--yes')
        Assert-ExitCode $extra 1 'extra version'
        Assert-Match $extra.Error 'one version' 'extra version error'

        $empty = New-EmptyRepo -Name 'tag-empty'
        $noHead = Invoke-TestGit -Repo $empty -Arguments @('release', 'tag', '1.2.3', '--yes')
        Assert-ExitCode $noHead 1 'empty repository tag'
        Assert-Match $noHead.Error 'no commits' 'empty repository tag error'
    }

    Test-Case 'release publish pushes the tag and creates a release' {
        $release = New-ReleaseRepo -Name 'publish-success' -Tag 'v1.2.3'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $result 0 'publish success'
        Assert-Match $result.Text 'Release published: https://github.com/example/demo/releases/tag/v1.2.3' 'publish url'
        $calls = Get-FakeCalls
        Assert-Match $calls 'release create v1.2.3' 'release create call'
        Assert-Match $calls '--repo example/demo' 'release repo argument'
        Assert-Match $calls '--verify-tag' 'verify tag argument'
        Assert-Match $calls '--title=v1.2.3' 'default release title'
        Assert-Match $calls '--generate-notes' 'generated notes'
        Assert-NotMatch $calls '--draft' 'draft argument'
        Assert-NotMatch $calls '--prerelease' 'prerelease argument'
        $remoteTag = Get-BareTag -Release $release -Tag 'v1.2.3'
        Assert-ExitCode $remoteTag 0 'remote tag exists'
        Assert-Equal $release.Head $remoteTag.Text.Trim() 'remote tag target'
    }

    Test-Case 'release publish requires confirmation before pushing' {
        $release = New-ReleaseRepo -Name 'publish-confirm' -Tag 'v1.2.3'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3') -InputText 'n'
        Assert-ExitCode $result 0 'cancelled publish'
        Assert-Match $result.Text 'Cancelled' 'publish cancel'
        Assert-NotMatch (Get-FakeCalls) 'release create' 'release create after cancel'
        $remoteTag = Get-BareTag -Release $release -Tag 'v1.2.3'
        Assert-ExitCode $remoteTag 1 'remote tag after cancel'
    }

    Test-Case 'release publish accepts an existing matching remote tag' {
        $release = New-ReleaseRepo -Name 'publish-existing-tag' -Tag 'v1.2.3'
        Set-StateText 'remote-tag-v1.2.3.txt' $release.Head
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $result 0 'existing remote tag publish'
        Assert-Match $result.Text 'tag already exists at HEAD' 'existing remote tag state'
        Assert-Match $result.Text 'Release published' 'existing remote tag release'
    }

    Test-Case 'release publish refuses a remote tag at another commit' {
        $release = New-ReleaseRepo -Name 'publish-remote-conflict' -Tag 'v1.2.3'
        Set-StateText 'remote-tag-v1.2.3.txt' ('0' * 40)
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $result 1 'remote tag conflict'
        Assert-Match $result.Error 'remote tag .* points to 000000000000' 'remote conflict error'
        Assert-NotMatch (Get-FakeCalls) 'release create' 'release create after conflict'
    }

    Test-Case 'release publish refuses an existing GitHub release' {
        $release = New-ReleaseRepo -Name 'publish-release-conflict' -Tag 'v1.2.3'
        Set-StateJson 'release.json' ([pscustomobject]@{
            tagName      = 'v1.2.3'
            url          = 'https://github.com/example/demo/releases/tag/v1.2.3'
            isDraft      = $false
            isPrerelease = $false
        })
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $result 1 'existing release'
        Assert-Match $result.Error 'already exists' 'existing release error'
        Assert-NotMatch (Get-FakeCalls) 'release create' 'release create after existing release'
    }

    Test-Case 'release publish validates the local tag and HEAD' {
        $release = New-ReleaseRepo -Name 'publish-tag-state' -Tag 'v1.2.3'
        Invoke-SetupGit $release.Repo @('tag', '-d', 'v1.2.3') | Out-Null
        $missing = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $missing 1 'missing local tag'
        Assert-Match $missing.Error 'does not exist' 'missing local tag error'

        $release = New-ReleaseRepo -Name 'publish-tag-old' -Tag 'v1.2.3'
        Add-TestCommit -Repo $release.Repo -FileName 'newer.txt' -Content 'newer' | Out-Null
        $old = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $old 1 'tag not at HEAD'
        Assert-Match $old.Error 'not HEAD' 'tag not at HEAD error'
    }

    Test-Case 'release publish validates the branch and worktree' {
        $release = New-ReleaseRepo -Name 'publish-branch' -Tag 'v1.2.3'
        Invoke-SetupGit $release.Repo @('checkout', '-b', 'feature') | Out-Null
        $wrongBranch = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $wrongBranch 1 'wrong branch publish'
        Assert-Match $wrongBranch.Error 'requires the default branch' 'wrong branch error'

        $release = New-ReleaseRepo -Name 'publish-dirty' -Tag 'v1.2.3'
        Set-Content -LiteralPath (Join-Path $release.Repo 'dirty.txt') -Value 'dirty' -Encoding utf8
        $dirty = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $dirty 1 'dirty publish'
        Assert-Match $dirty.Error 'worktree must be clean' 'dirty publish error'

        $release = New-ReleaseRepo -Name 'publish-detached' -Tag 'v1.2.3'
        Invoke-SetupGit $release.Repo @('checkout', '--detach') | Out-Null
        $detached = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $detached 1 'detached publish'
        Assert-Match $detached.Error 'detached HEAD' 'detached publish error'
    }

    Test-Case 'release publish requires the branch to match origin' {
        $release = New-ReleaseRepo -Name 'publish-unpushed' -Tag 'v1.2.3'
        Invoke-SetupGit $release.Repo @('update-ref', '-d', 'refs/remotes/origin/main') | Out-Null
        $unpushed = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $unpushed 1 'unpushed branch publish'
        Assert-Match $unpushed.Error 'not pushed to origin' 'unpushed publish error'

        $release = New-ReleaseRepo -Name 'publish-out-of-sync'
        Add-TestCommit -Repo $release.Repo -FileName 'newer.txt' -Content 'newer' | Out-Null
        Invoke-SetupGit $release.Repo @('tag', '-a', 'v1.2.3', '-m', 'Release v1.2.3', 'HEAD') | Out-Null
        $outOfSync = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $outOfSync 1 'out of sync publish'
        Assert-Match $outOfSync.Error 'does not match origin' 'out of sync publish error'
    }

    Test-Case 'release publish supports title, notes, draft, and prerelease' {
        $release = New-ReleaseRepo -Name 'publish-options' -Tag 'v1.2.3'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--title', 'Custom title', '--notes', 'Release notes', '--draft', '--prerelease', '--yes'
        )
        Assert-ExitCode $result 0 'publish options'
        Assert-Match $result.Text 'Title: Custom title' 'custom title output'
        Assert-Match $result.Text 'Draft: yes' 'draft output'
        Assert-Match $result.Text 'Prerelease: yes' 'prerelease output'
        $calls = Get-FakeCalls
        Assert-Match $calls '--title=Custom title' 'custom title argument'
        Assert-Match $calls '--notes=Release notes' 'notes argument'
        Assert-Match $calls '--draft' 'draft argument'
        Assert-Match $calls '--prerelease' 'prerelease argument'
        Assert-NotMatch $calls '--generate-notes' 'generated notes with explicit notes'
    }

    Test-Case 'release publish reads notes files' {
        $release = New-ReleaseRepo -Name 'publish-notes-file' -Tag 'v1.2.3'
        $notesPath = Join-Path $script:SuiteRoot 'publish-notes.md'
        [System.IO.File]::WriteAllText($notesPath, 'Notes from file')
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--notes-file', $notesPath, '--yes'
        )
        Assert-ExitCode $result 0 'notes file publish'
        $calls = Get-FakeCalls
        Assert-Match $calls '--notes=Notes from file' 'notes file content'
        Assert-NotMatch $calls '--generate-notes' 'generated notes with notes file'
    }

    Test-Case 'release publish validates notes and titles' {
        $release = New-ReleaseRepo -Name 'publish-input-validation' -Tag 'v1.2.3'
        $conflict = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--notes', 'text', '--notes-file', 'notes.md', '--yes'
        )
        Assert-ExitCode $conflict 1 'notes conflict'
        Assert-Match $conflict.Error 'cannot be used together' 'notes conflict error'

        $missingFile = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--notes-file', 'missing.md', '--yes'
        )
        Assert-ExitCode $missingFile 1 'missing notes file'
        Assert-Match $missingFile.Error 'notes file does not exist' 'missing notes file error'

        $missingValue = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--title', '--yes'
        )
        Assert-ExitCode $missingValue 1 'missing option value'
        Assert-Match $missingValue.Error "option '--title' requires a value" 'missing option value error'


        [System.IO.File]::WriteAllText((Join-Path $release.Repo 'large.md'), ('x' * 125001))
        $large = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--notes-file', 'large.md', '--yes'
        )
        Assert-ExitCode $large 1 'large notes'
        Assert-Match $large.Error '125000' 'large notes error'

        $blank = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--title', ' ', '--yes'
        )
        Assert-ExitCode $blank 1 'blank title'
        Assert-Match $blank.Error 'non-empty|single line' 'blank title error'

        $longTitle = 'x' * 257
        $long = Invoke-TestGit -Repo $release.Repo -Arguments @(
            'release', 'publish', '1.2.3', '--title', $longTitle, '--yes'
        )
        Assert-ExitCode $long 1 'long title'
        Assert-Match $long.Error 'single line' 'long title error'
    }

    Test-Case 'release publish validates versions' {
        $release = New-ReleaseRepo -Name 'publish-version-validation' -Tag 'v1.2.3'
        $invalid = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', 'nope', '--yes')
        Assert-ExitCode $invalid 1 'invalid publish version'
        Assert-Match $invalid.Error 'not a valid semantic version' 'invalid publish version error'

        $missing = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '--yes')
        Assert-ExitCode $missing 1 'missing publish version'
        Assert-Match $missing.Error 'requires a version' 'missing publish version error'

        $extra = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '1.2.4', '--yes')
        Assert-ExitCode $extra 1 'extra publish version'
        Assert-Match $extra.Error 'one version' 'extra publish version error'
    }

    Test-Case 'release publish accepts a v prefix' {
        $release = New-ReleaseRepo -Name 'publish-v-prefix' -Tag 'v1.2.3'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', 'v1.2.3', '--yes')
        Assert-ExitCode $result 0 'v prefix publish'
        Assert-Match $result.Text 'Release published' 'v prefix publish success'
        Assert-Match (Get-FakeCalls) 'release create v1.2.3' 'v prefix release tag'
    }

    Test-Case 'release publish reports authentication and release lookup failures' {
        $release = New-ReleaseRepo -Name 'publish-auth' -Tag 'v1.2.3'
        Set-StateFailure @('auth')
        $auth = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $auth 1 'publish auth failure'
        Assert-Match ($auth.Error + $auth.Text) 'authenticated|authentication|gh auth login' 'publish auth error'

        $release = New-ReleaseRepo -Name 'publish-release-lookup' -Tag 'v1.2.3'
        Set-StateFailure @('release-view')
        $lookup = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $lookup 1 'publish release lookup failure'
        Assert-Match $lookup.Error 'could not check the GitHub release' 'publish lookup error'
        Assert-NotMatch (Get-FakeCalls) 'release create' 'release create after lookup failure'
    }

    Test-Case 'release publish reports a release creation failure after pushing' {
        $release = New-ReleaseRepo -Name 'publish-create-failure' -Tag 'v1.2.3'
        Set-StateFailure @('release-create')
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'publish', '1.2.3', '--yes')
        Assert-ExitCode $result 1 'release create failure'
        Assert-Match $result.Error 'was pushed, but creating the GitHub release failed' 'release create failure message'
        $remoteTag = Get-BareTag -Release $release -Tag 'v1.2.3'
        Assert-ExitCode $remoteTag 0 'tag remains after release failure'
    }

    Test-Case 'release rejects unknown commands' {
        $release = New-ReleaseRepo -Name 'unknown-command'
        $result = Invoke-TestGit -Repo $release.Repo -Arguments @('release', 'nope')
        Assert-ExitCode $result 1 'unknown release command'
        Assert-Match $result.Error 'unknown command' 'unknown release command error'
    }
}
finally {
    Complete-TestEnvironment
}
