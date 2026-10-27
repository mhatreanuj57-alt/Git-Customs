[CmdletBinding()]
param([switch]$Keep)

. (Join-Path $PSScriptRoot 'lib\TestHelpers.ps1')
Initialize-TestEnvironment -TestScriptRoot $PSScriptRoot -Suite 'pr-flow' -Keep:$Keep

$script:PrJson = @'
{"number":7,"title":"Add feature","state":"OPEN","url":"https://github.com/example/demo/pull/7","headRefName":"feature/x","baseRefName":"main","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"APPROVED"}
'@

function New-PrRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$OnMain
    )
    $repo = New-TestRepo -Path (Join-Path $script:SuiteRoot $Name)
    $mainHead = (& git -C $repo rev-parse HEAD).Trim()
    if (-not $OnMain) {
        Invoke-SetupGit $repo @('checkout', '-b', 'feature/x') | Out-Null
        Add-TestCommit -Repo $repo -FileName 'feature.txt' -Content 'feature' | Out-Null
    }
    $head = (& git -C $repo rev-parse HEAD).Trim()
    Set-OriginTracking -Repo $repo -Branch 'main' -Sha $mainHead
    if (-not $OnMain) {
        Set-OriginTracking -Repo $repo -Branch 'feature/x' -Sha $head
    }
    New-TestState -Name $Name | Out-Null
    Set-StateText 'defaultBranch' 'main'
    Set-StateText 'pr.json' $script:PrJson
    Set-StateText 'check-steps.json' '[{"name":"build","state":"SUCCESS","detailsUrl":"https://github.com/example/demo/actions/runs/1"}]'
    return $repo
}

function Set-Checks {
    param([Parameter(Mandatory = $true)][string]$Json)
    Set-StateText 'check-steps.json' $Json
    Reset-PrViewCount
}

try {
    Test-Case 'pr-flow help is available' {
        $repo = New-PrRepo -Name 'help'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', '-h')
        Assert-ExitCode $result 0 'pr-flow -h'
        Assert-Match $result.Text 'Usage: git pr-flow' 'help output'
        Assert-Match $result.Text '(?s)status.*create.*checks' 'help commands'
    }

    Test-Case 'pr-flow help is available for every command' {
        $repo = New-PrRepo -Name 'help-commands'
        foreach ($command in @('status', 'create', 'checks')) {
            $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', $command, '-h')
            Assert-ExitCode $result 0 "pr-flow $command -h"
            Assert-Match $result.Text "Usage: git pr-flow $command" "$command help"
        }
    }

    Test-Case 'pr-flow status shows a passing pull request' {
        $repo = New-PrRepo -Name 'status-pass'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $result 0 'status pass'
        Assert-Match $result.Text '#7 Add feature \[OPEN\]' 'pr heading'
        Assert-Match $result.Text 'https://github.com/example/demo/pull/7' 'pr url'
        Assert-Match $result.Text 'feature/x -> main' 'branches'
        Assert-Match $result.Text 'Checks: 1 passed, 0 pending, 0 failed \(1 total\)' 'check summary'
        Assert-Match (Get-FakeCalls) 'pr view feature/x' 'current branch selector'
    }

    Test-Case 'pr-flow status is the default command' {
        $repo = New-PrRepo -Name 'default-command'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow')
        Assert-ExitCode $result 0 'default status'
        Assert-Match $result.Text '#7 Add feature' 'default status heading'
    }

    Test-Case 'pr-flow status supports number and branch selectors' {
        $repo = New-PrRepo -Name 'status-selectors'
        $byNumber = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status', '--number', '7')
        Assert-ExitCode $byNumber 0 'status number'
        Assert-Match (Get-FakeCalls) 'pr view 7' 'number selector'

        Clear-FakeCalls
        $byBranch = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status', '--branch', 'feature/x')
        Assert-ExitCode $byBranch 0 'status branch'
        Assert-Match (Get-FakeCalls) 'pr view feature/x' 'branch selector'
    }

    Test-Case 'pr-flow status exits 1 for pending or failed checks' {
        $repo = New-PrRepo -Name 'status-pending'
        Set-Checks '[[{"name":"build","status":"IN_PROGRESS"},{"name":"lint","state":"PENDING"}]]'
        $pending = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $pending 1 'pending status'
        Assert-Match $pending.Text '2 pending' 'pending count'
        Assert-Match $pending.Text 'PENDING build' 'pending item'

        $repo = New-PrRepo -Name 'status-failed'
        Set-Checks '[{"name":"test","conclusion":"FAILURE"}]'
        $failed = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $failed 1 'failed status'
        Assert-Match $failed.Text '1 failed' 'failed count'
        Assert-Match $failed.Text 'FAIL    test' 'failed item'
    }

    Test-Case 'pr-flow status handles a pull request with no checks' {
        $repo = New-PrRepo -Name 'status-no-checks'
        Set-Checks '[]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $result 0 'no checks status'
        Assert-Match $result.Text '0 passed, 0 pending, 0 failed \(0 total\)' 'no checks summary'
    }

    Test-Case 'pr-flow status shows a draft pull request' {
        $repo = New-PrRepo -Name 'status-draft'
        Set-StateText 'pr.json' '{"number":8,"title":"Draft work","state":"OPEN","url":"https://github.com/example/demo/pull/8","headRefName":"feature/x","baseRefName":"main","isDraft":true,"mergeable":"UNKNOWN","reviewDecision":""}'
        Set-Checks '[]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $result 0 'draft status'
        Assert-Match $result.Text '\[OPEN, draft\]' 'draft label'
    }

    Test-Case 'pr-flow status reports a missing pull request' {
        $repo = New-PrRepo -Name 'status-missing'
        Remove-Item -LiteralPath (Join-Path $script:CurrentState 'pr.json') -Force
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $result 1 'missing pull request'
        Assert-Match ($result.Error + $result.Text) 'no pull requests found|pull request' 'missing pr error'
    }

    Test-Case 'pr-flow validates selectors and intervals' {
        $repo = New-PrRepo -Name 'selector-errors'
        $both = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status', '--number', '7', '--branch', 'feature/x')
        Assert-ExitCode $both 1 'both selectors'
        Assert-Match $both.Error 'cannot be used together' 'selector conflict'

        $number = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status', '--number', 'abc')
        Assert-ExitCode $number 1 'invalid number'
        Assert-Match $number.Error 'positive integer' 'number error'

        $interval = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'checks', '--interval', '0')
        Assert-ExitCode $interval 1 'invalid interval'
        Assert-Match $interval.Error 'interval' 'interval error'

        $timeout = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'checks', '--timeout', '0')
        Assert-ExitCode $timeout 1 'invalid timeout'
        Assert-Match $timeout.Error 'timeout' 'timeout error'
    }

    Test-Case 'pr-flow checks reports pending once without waiting' {
        $repo = New-PrRepo -Name 'checks-pending'
        Set-Checks '[{"name":"build","status":"IN_PROGRESS"}]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'checks')
        Assert-ExitCode $result 1 'pending checks'
        Assert-Match $result.Text '1 pending' 'pending checks count'
        Assert-Match $result.Text 'PENDING build' 'pending checks item'
        Assert-Match (Get-FakeCalls) 'pr view feature/x' 'checks pr view'
    }

    Test-Case 'pr-flow checks --watch waits for pending checks to pass' {
        $repo = New-PrRepo -Name 'checks-watch'
        Set-Checks '[[{"name":"build","status":"IN_PROGRESS"}],[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'checks', '--watch', '--interval', '1', '--timeout', '10')
        Assert-ExitCode $result 0 'watch success'
        Assert-Match $result.Text 'All checks completed successfully' 'watch success message'
        Assert-Match $result.Text '1 passed, 0 pending, 0 failed \(1 total\)' 'watch final summary'
    }

    Test-Case 'pr-flow checks --watch reports failures after polling' {
        $repo = New-PrRepo -Name 'checks-watch-fail'
        Set-Checks '[[{"name":"build","status":"IN_PROGRESS"}],[{"name":"build","conclusion":"FAILURE"}]]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'checks', '--watch', '--interval', '1', '--timeout', '10')
        Assert-ExitCode $result 1 'watch failure'
        Assert-Match $result.Text 'Checks finished with failures' 'watch failure message'
    }

    Test-Case 'pr-flow checks --watch times out while checks remain pending' {
        $repo = New-PrRepo -Name 'checks-watch-timeout'
        Set-Checks '[{"name":"build","status":"IN_PROGRESS"}]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'checks', '--watch', '--interval', '1', '--timeout', '1')
        Assert-ExitCode $result 1 'watch timeout'
        Assert-Match $result.Text 'Timed out after 1 second' 'timeout message'
    }

    Test-Case 'pr-flow create requires confirmation and creates a pull request' {
        $repo = New-PrRepo -Name 'create-confirm'
        $cancelled = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Test title') -InputText 'n'
        Assert-ExitCode $cancelled 0 'cancelled create'
        Assert-Match $cancelled.Text 'Cancelled' 'cancel message'
        Assert-NotMatch (Get-FakeCalls) 'pr create' 'create called after cancellation'

        Clear-FakeCalls
        $created = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Test title', '--body', 'Body text', '--yes')
        Assert-ExitCode $created 0 'confirmed create'
        Assert-Match $created.Text 'Pull request created' 'create success'
        Assert-Match $created.Text 'https://github.com/example/demo/pull/42' 'create url'
        $calls = Get-FakeCalls
        Assert-Match $calls 'pr create' 'create call'
        Assert-Match $calls '--head feature/x' 'head argument'
        Assert-Match $calls '--base main' 'base argument'
        Assert-Match $calls '--title=Test title' 'title argument'
        Assert-Match $calls '--body=Body text' 'body argument'
        Assert-NotMatch $calls '--draft' 'draft argument'
    }

    Test-Case 'pr-flow create supports drafts and files' {
        $repo = New-PrRepo -Name 'create-draft-file'
        [System.IO.File]::WriteAllText((Join-Path $repo 'body.md'), 'Body from file')
        $result = Invoke-TestGit -Repo $repo -Arguments @(
            'pr-flow', 'create', '--title', 'Draft title', '--body-file', 'body.md', '--draft', '--yes'
        )
        Assert-ExitCode $result 0 'draft create'
        $calls = Get-FakeCalls
        Assert-Match $calls '--draft' 'draft argument'
        Assert-Match $calls '--body=Body from file' 'body file content'
        Assert-Match $result.Text 'Draft: yes' 'draft output'
    }

    Test-Case 'pr-flow create uses the repository default branch' {
        $repo = New-PrRepo -Name 'create-default-base'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Default base', '--yes')
        Assert-ExitCode $result 0 'default base create'
        $calls = Get-FakeCalls
        Assert-Match $calls 'repo view example/demo --json defaultBranchRef' 'default branch lookup'
        Assert-Match $calls '--base main' 'default base argument'
    }

    Test-Case 'pr-flow create refuses an existing open pull request' {
        $repo = New-PrRepo -Name 'create-duplicate'
        Set-StateText 'pr-list.json' '[{"number":9,"url":"https://github.com/example/demo/pull/9","title":"Existing","isDraft":false}]'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Duplicate', '--yes')
        Assert-ExitCode $result 1 'duplicate create'
        Assert-Match $result.Error 'already exists' 'duplicate error'
        Assert-NotMatch (Get-FakeCalls) 'pr create' 'duplicate create call'
    }

    Test-Case 'pr-flow create refuses unpushed or out-of-sync branches' {
        $repo = New-PrRepo -Name 'create-unpushed'
        Invoke-SetupGit $repo @('update-ref', '-d', 'refs/remotes/origin/feature/x') | Out-Null
        $unpushed = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Unpushed', '--yes')
        Assert-ExitCode $unpushed 1 'unpushed branch'
        Assert-Match $unpushed.Error 'has not been pushed' 'unpushed error'

        $repo = New-PrRepo -Name 'create-out-of-sync'
        Add-TestCommit -Repo $repo -FileName 'ahead.txt' -Content 'ahead' | Out-Null
        $ahead = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Ahead', '--yes')
        Assert-ExitCode $ahead 1 'out of sync branch'
        Assert-Match $ahead.Error 'does not match origin' 'out of sync error'
    }

    Test-Case 'pr-flow create validates base branches and detached HEAD' {
        $repo = New-PrRepo -Name 'create-base-errors'
        $missing = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Bad base', '--base', 'missing', '--yes')
        Assert-ExitCode $missing 1 'missing base'
        Assert-Match $missing.Error 'was not found locally' 'missing base error'

        $same = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Same base', '--base', 'feature/x', '--yes')
        Assert-ExitCode $same 1 'base equals head'
        Assert-Match $same.Error 'cannot be the current branch' 'same base error'

        Invoke-SetupGit $repo @('checkout', '--detach') | Out-Null
        $detached = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Detached', '--yes')
        Assert-ExitCode $detached 1 'detached create'
        Assert-Match $detached.Error 'detached HEAD' 'detached error'
    }

    Test-Case 'pr-flow create validates titles and body inputs' {
        $repo = New-PrRepo -Name 'create-validation'
        $missing = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--yes')
        Assert-ExitCode $missing 1 'missing title'
        Assert-Match $missing.Error '--title is required' 'missing title error'

        $blank = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', ' ', '--yes')
        Assert-ExitCode $blank 1 'blank title'
        Assert-Match $blank.Error 'non-empty|single line' 'blank title error'

        $longTitle = 'x' * 257
        $long = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', $longTitle, '--yes')
        Assert-ExitCode $long 1 'long title'
        Assert-Match $long.Error 'single line' 'long title error'

        $conflict = Invoke-TestGit -Repo $repo -Arguments @(
            'pr-flow', 'create', '--title', 'Conflict', '--body', 'text', '--body-file', 'body.md', '--yes'
        )
        Assert-ExitCode $conflict 1 'body conflict'
        Assert-Match $conflict.Error 'cannot be used together' 'body conflict error'

        $missingFile = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'File', '--body-file', 'missing.md', '--yes')
        Assert-ExitCode $missingFile 1 'missing body file'
        Assert-Match $missingFile.Error 'body file does not exist' 'missing body file error'
    }

    Test-Case 'pr-flow create rejects an oversized body' {
        $repo = New-PrRepo -Name 'create-large-body'
        [System.IO.File]::WriteAllText((Join-Path $repo 'large.md'), ('x' * 65537))
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'create', '--title', 'Large', '--body-file', 'large.md', '--yes')
        Assert-ExitCode $result 1 'large body'
        Assert-Match $result.Error '65536' 'large body error'
    }

    Test-Case 'pr-flow reports authentication and GitHub failures' {
        $repo = New-PrRepo -Name 'auth-failure'
        Set-StateFailure @('auth')
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $result 1 'auth failure'
        Assert-Match ($result.Error + $result.Text) 'authenticated|authentication|gh auth login' 'auth error'

        $repo = New-PrRepo -Name 'pr-view-failure'
        Set-StateFailure @('pr-view')
        $failure = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'status')
        Assert-ExitCode $failure 1 'pr view failure'
        Assert-Match ($failure.Error + $failure.Text) 'no pull requests found|pull request' 'pr view error'
    }

    Test-Case 'pr-flow rejects unknown commands' {
        $repo = New-PrRepo -Name 'unknown-command'
        $result = Invoke-TestGit -Repo $repo -Arguments @('pr-flow', 'nope')
        Assert-ExitCode $result 1 'unknown pr-flow command'
        Assert-Match $result.Error 'unknown command' 'unknown command error'
    }
}
finally {
    Complete-TestEnvironment
}
