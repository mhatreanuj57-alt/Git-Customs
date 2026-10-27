[CmdletBinding()]
param([switch]$Keep)

. (Join-Path $PSScriptRoot 'lib\TestHelpers.ps1')
Initialize-TestEnvironment -TestScriptRoot $PSScriptRoot -Suite 'work' -Keep:$Keep

try {
    $repo = New-TestRepo -Path (Join-Path $script:SuiteRoot 'repo')
    $mainHead = (& git -C $repo rev-parse HEAD).Trim()
    Set-OriginTracking -Repo $repo -Branch 'main' -Sha $mainHead
    $worktreeRoot = Join-Path $script:SuiteRoot 'worktrees'

    Test-Case 'work help is available' {
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', '-h')
        Assert-ExitCode $result 0 'work -h'
        Assert-Match $result.Text 'Usage: git work' 'help output'
    }

    Test-Case 'work list shows the current main worktree' {
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'list')
        Assert-ExitCode $result 0 'work list'
        Assert-Match $result.Text 'main' 'work list branch'
        Assert-Match $result.Text 'current' 'work list status'
        Assert-Match $result.Text '1 worktree\(s\)' 'work list count'
    }

    Test-Case 'work add creates a new branch and worktree' {
        $path = Join-Path $worktreeRoot 'feature-one'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/one', '--path', $path)
        Assert-ExitCode $result 0 'work add'
        Assert-True (Test-Path -LiteralPath $path -PathType Container) 'worktree directory was not created'
        $branch = (& git -C $repo branch --list 'feature/one').Trim()
        Assert-Match $branch 'feature/one' 'created branch'
        $list = Invoke-TestGit -Repo $repo -Arguments @('work', 'list')
        Assert-Match $list.Text 'feature/one' 'work list shows feature branch'
        Assert-Match $list.Text '2 worktree\(s\)' 'work list count after add'
    }

    Test-Case 'work add refuses a branch that is already checked out' {
        $path = Join-Path $worktreeRoot 'duplicate'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/one', '--path', $path)
        Assert-ExitCode $result 1 'duplicate worktree add'
        Assert-Match $result.Error 'already checked out' 'duplicate error'
        Assert-False (Test-Path -LiteralPath $path) 'duplicate worktree directory should not exist'
    }

    Test-Case 'work add validates the base and target path' {
        $badBase = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/bad-base', '--base', 'does-not-exist')
        Assert-ExitCode $badBase 1 'bad base'
        Assert-Match $badBase.Error 'does not resolve to a commit' 'bad base error'

        $inside = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/inside', '--path', (Join-Path $repo 'inside'))
        Assert-ExitCode $inside 1 'inside path'
        Assert-Match $inside.Error 'outside the current worktree' 'inside path error'
    }

    Test-Case 'work add refuses the main branch' {
        $path = Join-Path $worktreeRoot 'main-copy'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'main', '--path', $path)
        Assert-ExitCode $result 1 'add main'
        Assert-Match $result.Error 'already checked out' 'add main error'
    }

    Test-Case 'work remove refuses the main worktree' {
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'remove', 'main', '--yes')
        Assert-ExitCode $result 1 'remove main'
        Assert-Match $result.Error 'main worktree cannot be removed' 'remove main error'
    }

    Test-Case 'work remove can be cancelled at the confirmation prompt' {
        $path = Join-Path $worktreeRoot 'feature-one'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'remove', 'feature/one') -InputText 'n'
        Assert-ExitCode $result 0 'cancel remove'
        Assert-Match $result.Text 'Cancelled' 'cancel output'
        Assert-True (Test-Path -LiteralPath $path -PathType Container) 'cancelled remove deleted the worktree'
    }

    Test-Case 'work remove keeps the branch and removes a clean worktree' {
        $path = Join-Path $worktreeRoot 'feature-one'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'remove', 'feature/one', '--yes')
        Assert-ExitCode $result 0 'remove clean worktree'
        Assert-False (Test-Path -LiteralPath $path) 'clean worktree still exists'
        $branch = (& git -C $repo branch --list 'feature/one').Trim()
        Assert-Match $branch 'feature/one' 'branch was deleted'
        Assert-Match $result.Text 'Branch ''feature/one'' was kept' 'branch retention message'
    }

    Test-Case 'work add can check out an existing branch' {
        $path = Join-Path $worktreeRoot 'feature-one-again'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/one', '--path', $path)
        Assert-ExitCode $result 0 'add existing branch'
        Assert-Match $result.Text 'Checked out existing branch' 'existing branch output'
        Assert-True (Test-Path -LiteralPath $path -PathType Container) 'existing branch worktree missing'
    }

    Test-Case 'work remove refuses dirty worktrees without force' {
        $path = Join-Path $worktreeRoot 'feature-one-again'
        Set-Content -LiteralPath (Join-Path $path 'dirty.txt') -Value 'dirty' -Encoding utf8
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'remove', 'feature/one', '--yes')
        Assert-ExitCode $result 1 'dirty remove'
        Assert-Match $result.Error 'dirty' 'dirty remove error'
        Assert-True (Test-Path -LiteralPath $path -PathType Container) 'dirty worktree was removed without force'
    }

    Test-Case 'work remove --force discards dirty worktree changes' {
        $path = Join-Path $worktreeRoot 'feature-one-again'
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'remove', 'feature/one', '--force', '--yes')
        Assert-ExitCode $result 0 'force remove'
        Assert-Match $result.Text 'WARNING' 'force warning'
        Assert-False (Test-Path -LiteralPath $path) 'forced worktree still exists'
    }

    Test-Case 'work prune previews stale metadata and applies only on request' {
        $path = Join-Path $worktreeRoot 'feature-prune'
        $added = Invoke-TestGit -Repo $repo -Arguments @('work', 'add', 'feature/prune', '--path', $path)
        Assert-ExitCode $added 0 'add prune branch'
        Remove-Item -LiteralPath $path -Recurse -Force

        $list = Invoke-TestGit -Repo $repo -Arguments @('work', 'list')
        Assert-Match $list.Text 'missing' 'stale worktree not marked missing'

        $preview = Invoke-TestGit -Repo $repo -Arguments @('work', 'prune')
        Assert-ExitCode $preview 0 'prune preview'
        Assert-Match $preview.Text 'Dry run only' 'prune preview message'

        $stillStale = Invoke-TestGit -Repo $repo -Arguments @('work', 'list')
        Assert-Match $stillStale.Text 'missing' 'prune preview changed metadata'

        $applied = Invoke-TestGit -Repo $repo -Arguments @('work', 'prune', '--apply', '--yes')
        Assert-ExitCode $applied 0 'prune apply'
        $clean = Invoke-TestGit -Repo $repo -Arguments @('work', 'list')
        Assert-NotMatch $clean.Text 'missing' 'prune apply left stale metadata'
    }

    Test-Case 'work prune rejects --apply with --dry-run' {
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'prune', '--apply', '--dry-run')
        Assert-ExitCode $result 1 'prune conflicting flags'
        Assert-Match $result.Error 'cannot be used together' 'prune flag error'
    }

    Test-Case 'work remove reports an unknown selector' {
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'remove', 'does-not-exist', '--yes')
        Assert-ExitCode $result 1 'remove unknown worktree'
        Assert-Match $result.Error 'no worktree matches' 'unknown selector error'
    }

    Test-Case 'work rejects unknown commands' {
        $result = Invoke-TestGit -Repo $repo -Arguments @('work', 'nope')
        Assert-ExitCode $result 1 'unknown work command'
        Assert-Match $result.Error 'unknown command' 'unknown command error'
    }
}
finally {
    Complete-TestEnvironment
}
