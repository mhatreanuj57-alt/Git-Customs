$ErrorActionPreference = 'Continue'

$stateDir = $env:FAKE_GH_STATE
if ([string]::IsNullOrWhiteSpace($stateDir)) {
    $stateDir = Join-Path $env:TEMP 'fake-gh-state'
}
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

function Get-StatePath {
    param([string]$Name)
    return (Join-Path $stateDir $Name)
}

function Read-StateText {
    param([string]$Name, [string]$Default = '')
    $path = Get-StatePath $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return $Default
    }
    return [System.IO.File]::ReadAllText($path)
}

function Read-StateJson {
    param([string]$Name)
    $text = Read-StateText $Name
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-Json {
    param($Value, [int]$Depth = 12)
    if ($null -eq $Value) {
        Write-Output 'null'
        return
    }
    Write-Output ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-JsonArray {
    param($Value, [int]$Depth = 12)
    $items = @($Value)
    if ($items.Count -eq 0) {
        Write-Output '[]'
        return
    }
    $json = ConvertTo-Json -InputObject $items -Depth $Depth -Compress
    if (-not $json.TrimStart().StartsWith('[')) {
        $json = "[$json]"
    }
    Write-Output $json
}

function Test-Failure {
    param([string]$Name)
    $path = Get-StatePath 'fail.txt'
    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if (([string]$line).Trim() -ieq $Name) {
            return $true
        }
    }
    return $false
}

function Add-Call {
    $path = Get-StatePath 'calls.log'
    $line = ($args | ForEach-Object { [string]$_ }) -join ' '
    [System.IO.File]::AppendAllText($path, "$line`n")
}

function Get-DefaultBranch {
    $value = (Read-StateText 'defaultBranch' 'main').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'main'
    }
    return $value
}

function Get-Rollup {
    $steps = Read-StateJson 'check-steps.json'
    if ($null -ne $steps) {
        $stepItems = @($steps)
        $counterPath = Get-StatePath 'pr-view-count.txt'
        $count = 0
        if (Test-Path -LiteralPath $counterPath) {
            [void][int]::TryParse((Get-Content -LiteralPath $counterPath -Raw).Trim(), [ref]$count)
        }
        $index = [Math]::Min($count, [Math]::Max(0, $stepItems.Count - 1))
        [System.IO.File]::WriteAllText($counterPath, [string]($count + 1))
        $step = $stepItems[$index]
        if ($null -ne $step -and $null -ne $step.PSObject.Properties['value']) {
            return [object[]]@($step.value)
        }
        if ($step -is [System.Array]) {
            return [object[]]@($step)
        }
        return [object[]]@($stepItems)
    }
    $pr = Read-StateJson 'pr.json'
    if ($null -eq $pr -or $null -eq $pr.statusCheckRollup) {
        return [object[]]@()
    }
    return [object[]]@($pr.statusCheckRollup)
}

Add-Call @args

if (Test-Failure 'all') {
    [Console]::Error.WriteLine('fake gh: all operations are configured to fail')
    exit 1
}
if ($args.Count -eq 0) {
    [Console]::Error.WriteLine('fake gh: no command')
    exit 1
}

$command = [string]$args[0]
$subcommand = ''
if ($args.Count -gt 1) {
    $subcommand = [string]$args[1]
}

if ($command -eq 'auth' -and $subcommand -eq 'status') {
    if (Test-Failure 'auth') {
        [Console]::Error.WriteLine('gh: authentication required')
        exit 1
    }
    $account = [pscustomobject]@{
        active = $true
        state  = 'success'
        login  = 'fake-user'
        scopes = 'repo,workflow'
    }
    Write-Json ([pscustomobject]@{ hosts = [pscustomobject]@{ 'github.com' = @($account) } })
    exit 0
}

if ($command -eq 'repo' -and $subcommand -eq 'view') {
    if (Test-Failure 'repo-view') {
        [Console]::Error.WriteLine('gh: repository not found')
        exit 1
    }
    Write-Json ([pscustomobject]@{
        nameWithOwner    = 'example/demo'
        defaultBranchRef = [pscustomobject]@{ name = (Get-DefaultBranch) }
    })
    exit 0
}

if ($command -eq 'pr' -and $subcommand -eq 'view') {
    if (Test-Failure 'pr-view') {
        [Console]::Error.WriteLine('no pull requests found for branch')
        exit 1
    }
    $pr = Read-StateJson 'pr.json'
    if ($null -eq $pr) {
        [Console]::Error.WriteLine('no pull requests found for branch')
        exit 1
    }
    $rollup = Get-Rollup
    $result = [ordered]@{}
    foreach ($property in @($pr.PSObject.Properties)) {
        $result[$property.Name] = $property.Value
    }
    $result['statusCheckRollup'] = @($rollup)
    Write-Json ([pscustomobject]$result)
    exit 0
}

if ($command -eq 'pr' -and $subcommand -eq 'list') {
    if (Test-Failure 'pr-list') {
        [Console]::Error.WriteLine('gh: could not list pull requests')
        exit 1
    }
    $list = Read-StateJson 'pr-list.json'
    if ($null -eq $list) {
        Write-Output '[]'
        exit 0
    }
    Write-JsonArray @($list)
    exit 0
}

if ($command -eq 'pr' -and $subcommand -eq 'create') {
    if (Test-Failure 'pr-create') {
        [Console]::Error.WriteLine('gh: failed to create pull request')
        exit 1
    }
    Write-Output (Read-StateText 'pr-create-url' 'https://github.com/example/demo/pull/42').Trim()
    exit 0
}

if ($command -eq 'release' -and $subcommand -eq 'view') {
    if (Test-Failure 'release-view') {
        [Console]::Error.WriteLine('gh: API rate limit exceeded')
        exit 1
    }
    $release = Read-StateJson 'release.json'
    if ($null -eq $release) {
        [Console]::Error.WriteLine('release not found')
        exit 1
    }
    Write-Json $release
    exit 0
}

if ($command -eq 'release' -and $subcommand -eq 'create') {
    if (Test-Failure 'release-create') {
        [Console]::Error.WriteLine('gh: failed to create release')
        exit 1
    }
    Write-Output (Read-StateText 'release-create-url' 'https://github.com/example/demo/releases/tag/v1.0.0').Trim()
    exit 0
}

if ($command -eq 'api') {
    $apiPath = ''
    for ($index = 1; $index -lt $args.Count; $index++) {
        $argument = [string]$args[$index]
        if (-not $argument.StartsWith('-')) {
            $apiPath = $argument
            break
        }
    }
    if ($apiPath -match '^repos/[^/]+/[^/]+/git/ref/tags/(?<tag>.+)$') {
        $tag = $Matches['tag']
        $sha = (Read-StateText "remote-tag-$tag.txt" '').Trim()
        if ([string]::IsNullOrWhiteSpace($sha) -or $sha -eq 'MISSING') {
            [Console]::Error.WriteLine('gh: Not Found (HTTP 404)')
            exit 1
        }
        Write-Json ([pscustomobject]@{
            ref    = "refs/tags/$tag"
            object = [pscustomobject]@{ type = 'commit'; sha = $sha }
        })
        exit 0
    }
    if ($apiPath -match '^repos/[^/]+/[^/]+/git/tags/(?<sha>.+)$') {
        Write-Json ([pscustomobject]@{
            sha    = $Matches['sha']
            object = [pscustomobject]@{ type = 'commit'; sha = $Matches['sha'] }
        })
        exit 0
    }
    if (Test-Failure 'api') {
        [Console]::Error.WriteLine('gh: API failure')
        exit 1
    }
    [Console]::Error.WriteLine("fake gh: unsupported api path: $apiPath")
    exit 1
}

[Console]::Error.WriteLine("fake gh: unsupported command: $($args -join ' ')")
exit 1
