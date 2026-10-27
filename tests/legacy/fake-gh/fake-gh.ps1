$ErrorActionPreference = 'Stop'

$statePath = $env:FAKE_GH_STATE
$logPath = $env:FAKE_GH_LOG

if ([string]::IsNullOrWhiteSpace($statePath) -or -not (Test-Path -LiteralPath $statePath)) {
    [Console]::Error.WriteLine('fake gh: FAKE_GH_STATE is not configured')
    exit 1
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    $entry = [pscustomobject]@{
        Arguments = [string[]]@($args)
    }
    Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
}

function Get-Failure {
    param([string]$Name)
    if ($null -eq $state.failures) {
        return $null
    }
    $property = $state.failures.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return [string]$property.Value
}

function Stop-FakeGh {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Get-OptionValue {
    param([string[]]$AllArguments, [string]$Name)
    for ($i = 0; $i -lt $AllArguments.Count; $i++) {
        if ($AllArguments[$i] -eq $Name -and $i + 1 -lt $AllArguments.Count) {
            return [string]$AllArguments[$i + 1]
        }
        if ($AllArguments[$i].StartsWith($Name + '=')) {
            return $AllArguments[$i].Substring($Name.Length + 1)
        }
    }
    return $null
}

function Get-PositionalRunId {
    param([string[]]$AllArguments)
    for ($i = 2; $i -lt $AllArguments.Count; $i++) {
        if (-not $AllArguments[$i].StartsWith('-')) {
            return [string]$AllArguments[$i]
        }
    }
    return $null
}

if ($args.Count -eq 0) {
    Stop-FakeGh 'fake gh: missing command'
}

if ($args[0] -eq '--version') {
    Write-Output 'gh version 2.97.0 (fake)'
    exit 0
}

if ($args[0] -eq 'auth' -and $args.Count -ge 2 -and $args[1] -eq 'status') {
    $failure = Get-Failure 'auth status'
    if ($null -ne $failure) {
        Stop-FakeGh $failure
    }
    $auth = $state.auth
    if ($null -eq $auth) {
        $auth = [pscustomobject]@{
            hosts = [pscustomobject]@{
                'github.com' = @(
                    [pscustomobject]@{
                        state = 'success'
                        active = $true
                        host = 'github.com'
                        login = 'tester'
                        tokenSource = 'keyring'
                        scopes = 'repo, workflow'
                        gitProtocol = 'https'
                    }
                )
            }
        }
    }
    Write-Output ($auth | ConvertTo-Json -Depth 20 -Compress)
    exit 0
}

if ($args[0] -eq 'workflow' -and $args.Count -ge 2 -and $args[1] -eq 'list') {
    $failure = Get-Failure 'workflow list'
    if ($null -ne $failure) {
        Stop-FakeGh $failure
    }
    $workflows = @()
    if ($null -ne $state.workflows) {
        $workflows = @($state.workflows)
    }
    Write-Output (ConvertTo-Json -InputObject @($workflows) -Depth 10 -Compress)
    exit 0
}

if ($args[0] -eq 'run' -and $args.Count -ge 2 -and $args[1] -eq 'list') {
    $failure = Get-Failure 'run list'
    if ($null -ne $failure) {
        Stop-FakeGh $failure
    }

    if ($null -ne $state.autoRecovery) {
        $recoveryConfig = $state.autoRecovery
        $currentHead = ''
        try {
            $currentHead = ((& git rev-parse --verify HEAD 2>$null) -join '').Trim()
        }
        catch {
            $currentHead = ''
        }
        $baseHead = [string]$recoveryConfig.baseHeadSha
        if (-not [string]::IsNullOrWhiteSpace($currentHead) -and $currentHead -cne $baseHead) {
            $existing = @($state.runs | Where-Object { [string]$_.headSha -ieq $currentHead })
            if ($existing.Count -eq 0) {
                $nextId = 900000
                foreach ($run in @($state.runs)) {
                    $candidate = [long]$run.databaseId + 1
                    if ($candidate -gt $nextId) {
                        $nextId = $candidate
                    }
                }
                $newRun = [pscustomobject]@{
                    databaseId = [long]$nextId
                    workflowName = [string]$recoveryConfig.workflowName
                    workflowPath = [string]$recoveryConfig.workflowPath
                    workflowDatabaseId = [long]$recoveryConfig.workflowDatabaseId
                    headBranch = [string]$recoveryConfig.branch
                    status = [string]$recoveryConfig.status
                    conclusion = [string]$recoveryConfig.conclusion
                    createdAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    displayTitle = [string]$recoveryConfig.title
                    event = 'push'
                    attempt = 1
                    headSha = $currentHead
                    url = "https://github.com/example/demo/actions/runs/$nextId"
                    jobs = @()
                }
                $state.runs = @($state.runs) + @($newRun)
                [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
            }
        }
    }

    $runs = @()
    if ($null -ne $state.runs) {
        $runs = @($state.runs)
    }
    $workflowSelector = Get-OptionValue $args '--workflow'
    if (-not [string]::IsNullOrWhiteSpace($workflowSelector)) {
        $runs = @($runs | Where-Object {
            [string]$_.workflowName -ieq $workflowSelector -or
            [string]$_.workflowPath -ieq $workflowSelector -or
            [string]$_.path -ieq $workflowSelector
        })
    }
    $branch = Get-OptionValue $args '--branch'
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        $runs = @($runs | Where-Object { [string]$_.headBranch -ceq $branch })
    }
    $limitText = Get-OptionValue $args '--limit'
    $limit = 20
    if (-not [string]::IsNullOrWhiteSpace($limitText)) {
        $limit = [int]$limitText
    }
    $runs = @($runs | Sort-Object { [long]$_.databaseId } -Descending | Select-Object -First $limit)
    Write-Output (ConvertTo-Json -InputObject @($runs) -Depth 20 -Compress)
    exit 0
}

if ($args[0] -eq 'run' -and $args.Count -ge 2 -and $args[1] -eq 'view') {
    $runId = Get-PositionalRunId $args
    $run = @($state.runs | Where-Object { [string]$_.databaseId -eq $runId }) | Select-Object -First 1
    if ($null -eq $run) {
        Stop-FakeGh "run $runId not found"
    }

    if ($args -contains '--log' -or $args -contains '--log-failed') {
        $failure = Get-Failure 'run log'
        if ($null -ne $failure) {
            Stop-FakeGh $failure
        }
        $jobId = Get-OptionValue $args '--job'
        if (-not [string]::IsNullOrWhiteSpace($jobId)) {
            $job = @($run.jobs | Where-Object { [string]$_.databaseId -eq $jobId }) | Select-Object -First 1
            if ($null -eq $job) {
                Stop-FakeGh "job $jobId not found in run $runId"
            }
            if ($args -contains '--log-failed' -and -not [string]::IsNullOrWhiteSpace([string]$job.failedLog)) {
                Write-Output ([string]$job.failedLog)
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$job.log)) {
                Write-Output ([string]$job.log)
            }
            else {
                Write-Output "job $jobId log"
            }
            exit 0
        }
        if ($args -contains '--log-failed' -and -not [string]::IsNullOrWhiteSpace([string]$run.failedLog)) {
            Write-Output ([string]$run.failedLog)
            exit 0
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$run.log)) {
            Write-Output ([string]$run.log)
        }
        else {
            Write-Output "run $runId log"
        }
        exit 0
    }

    $failure = Get-Failure 'run view'
    if ($null -ne $failure) {
        Stop-FakeGh $failure
    }

    if ($null -ne $state.transitions) {
        $transitionProperty = $state.transitions.PSObject.Properties[[string]$runId]
        if ($null -ne $transitionProperty) {
            $transition = $transitionProperty.Value
            $remaining = [int]$transition.remaining
            if ($remaining -le 0) {
                foreach ($propertyName in @('status', 'conclusion')) {
                    $valueProperty = $transition.PSObject.Properties[$propertyName]
                    if ($null -ne $valueProperty) {
                        $run.$propertyName = [string]$valueProperty.Value
                    }
                }
            }
            else {
                $transition.remaining = $remaining - 1
            }
            [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
        }
    }

    Write-Output ($run | ConvertTo-Json -Depth 20 -Compress)
    exit 0
}

if ($args[0] -eq 'run' -and $args.Count -ge 2 -and $args[1] -eq 'rerun') {
    $failure = Get-Failure 'run rerun'
    if ($null -ne $failure) {
        Stop-FakeGh $failure
    }
    $runId = Get-PositionalRunId $args
    $run = @($state.runs | Where-Object { [string]$_.databaseId -eq $runId }) | Select-Object -First 1
    if ($null -eq $run) {
        Stop-FakeGh "run $runId not found"
    }
    $mode = 'all'
    if ($args -contains '--failed') {
        $mode = 'failed'
    }
    $call = [pscustomobject]@{
        RunId = [string]$runId
        Mode  = $mode
    }
    if ($null -eq $state.rerunCalls) {
        $state | Add-Member -NotePropertyName rerunCalls -NotePropertyValue @() -Force
    }
    $state.rerunCalls = @($state.rerunCalls) + @($call)

    if ($null -ne $state.rerunTransitions) {
        $transitionProperty = $state.rerunTransitions.PSObject.Properties[[string]$runId]
        if ($null -ne $transitionProperty) {
            $transition = $transitionProperty.Value
            foreach ($propertyName in @('attempt', 'status', 'conclusion')) {
                $valueProperty = $transition.PSObject.Properties[$propertyName]
                if ($null -ne $valueProperty) {
                    $run.$propertyName = $valueProperty.Value
                }
            }
        }
    }

    [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
    Write-Output "Requested $mode rerun for run $runId"
    exit 0
}

Stop-FakeGh ("fake gh: unsupported command: " + ($args -join ' '))
