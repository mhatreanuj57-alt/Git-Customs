function Show-GitSecurityCheckUsage {
    Write-Output 'Usage: git security-check [--staged] [--strict] [--secrets-only|--workflows-only]'
    Write-Output ''
    Write-Output 'Scans tracked and untracked files for credential patterns, risky credential'
    Write-Output 'files, and common GitHub Actions security problems. Findings are redacted.'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  --staged          Scan staged file content instead of the working tree'
    Write-Output '  --secrets-only    Skip GitHub Actions workflow checks'
    Write-Output '  --workflows-only  Skip credential scanning'
    Write-Output '  --strict          Exit non-zero when warnings are found'
    Write-Output ''
    Write-Output 'Exit codes: 0 for clean or warnings, 1 for errors or warnings with --strict.'
}

function Get-GitSecuritySeverityRank {
    param([string]$Severity)

    if ($Severity -eq 'ERROR') { return 2 }
    if ($Severity -eq 'WARN') { return 1 }
    return 0
}

function New-GitSecurityFinding {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('ERROR', 'WARN')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Line = 0,
        [string]$Masked = '',
        [string]$Message = ''
    )

    [pscustomobject]@{
        Severity = $Severity
        Type     = $Type
        Path     = $Path
        Line     = $Line
        Masked   = $Masked
        Message  = $Message
    }
}

function Get-GitSecurityMaskedValue {
    param([string]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '***'
    }
    if ($text.Length -le 6) {
        return "*** ($($text.Length) chars)"
    }
    return "$($text.Substring(0, 4))*** ($($text.Length) chars)"
}

function Get-GitSecurityLineNumber {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][int]$Index
    )

    if ($Index -le 0) {
        return 1
    }
    return (($Content.Substring(0, $Index).Split("`n")).Count)
}

function Test-GitSecurityPlaceholderValue {
    param([string]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $true
    }
    return ($text -match '(?i)^(?:\$|<|%|your[-_]|example|sample|placeholder|changeme|change[-_]me|dummy|fake|redacted|none|null|todo|xxx|test[-_]?only)')
}

function Get-GitSecurityScanFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$Staged
    )

    if ($Staged) {
        $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('diff', '--cached', '--name-only', '--diff-filter=ACMR')
    }
    else {
        $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('ls-files', '--cached', '--others', '--exclude-standard')
    }

    $seen = @{}
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($result.Output)) {
        $path = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $normalized = $path.Replace('\', '/')
        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $files.Add($normalized)
    }
    return [object[]]$files.ToArray()
}

function Test-GitSecuritySkippedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $value = $Path.Replace('\', '/')
    $name = [System.IO.Path]::GetFileName($value)
    if ($value -match '(^|/)(?:\.git|node_modules|vendor|bin|obj|dist|build|coverage|__pycache__|\.venv|venv|packages|target)/') {
        return $true
    }
    if ($name -match '(?i)^(?:package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|Pipfile\.lock|composer\.lock|Gemfile\.lock)$') {
        return $true
    }
    if ($name -match '(?i)\.(?:min\.js|min\.css|map|png|jpg|jpeg|gif|ico|pdf|zip|gz|tgz|bz2|xz|7z|rar|exe|dll|bin|woff2?|ttf|otf|eot|mp[34]|mov|avi|mkv|jar|class|pyc|so|dylib|deb|rpm|iso|img)$') {
        return $true
    }
    return $false
}

function Get-GitSecurityFileContent {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Staged,
        [int]$MaxBytes = 2097152
    )

    if ($Staged) {
        $sizeResult = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('cat-file', '-s', ":$Path") -AllowFailure
        $size = 0
        if ($sizeResult.ExitCode -eq 0 -and -not [int]::TryParse($sizeResult.Text.Trim(), [ref]$size)) {
            $size = 0
        }
        if ($sizeResult.ExitCode -ne 0 -or $size -gt $MaxBytes) {
            return $null
        }
        $contentResult = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('show', ":$Path") -AllowFailure
        if ($contentResult.ExitCode -ne 0) {
            return $null
        }
        $text = ($contentResult.Output -join "`n")
        if ($text.IndexOf([char]0) -ge 0) {
            return $null
        }
        return $text
    }

    $fullPath = Join-Path $RepoRoot $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $fullPath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -gt $MaxBytes) {
        return $null
    }
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        $buffer = New-Object byte[] 8192
        $read = $stream.Read($buffer, 0, $buffer.Length)
        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) {
                return $null
            }
        }
    }
    finally {
        $stream.Dispose()
    }
    return [System.IO.File]::ReadAllText($fullPath)
}

function Get-GitSecurityContentPatterns {
    return @(
        [pscustomobject]@{
            Type     = 'GitHub token'
            Severity = 'ERROR'
            Regex    = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'
        },
        [pscustomobject]@{
            Type     = 'AWS access key'
            Severity = 'ERROR'
            Regex    = '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
        },
        [pscustomobject]@{
            Type     = 'Private key block'
            Severity = 'ERROR'
            Regex    = '-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----'
        },
        [pscustomobject]@{
            Type     = 'Google API key'
            Severity = 'ERROR'
            Regex    = '\bAIza[0-9A-Za-z_-]{35}\b'
        },
        [pscustomobject]@{
            Type     = 'Slack token'
            Severity = 'ERROR'
            Regex    = '\bxox[baprs]-[0-9A-Za-z-]{10,}\b'
        },
        [pscustomobject]@{
            Type     = 'Stripe live key'
            Severity = 'ERROR'
            Regex    = '\b(?:sk|rk)_live_[0-9A-Za-z]{16,}\b'
        },
        [pscustomobject]@{
            Type     = 'OpenAI/Anthropic-style key'
            Severity = 'ERROR'
            Regex    = '\bsk-[A-Za-z0-9_-]{20,}\b'
        },
        [pscustomobject]@{
            Type     = 'Hugging Face token'
            Severity = 'ERROR'
            Regex    = '\bhf_[A-Za-z0-9]{20,}\b'
        },
        [pscustomobject]@{
            Type     = 'SendGrid key'
            Severity = 'ERROR'
            Regex    = '\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b'
        },
        [pscustomobject]@{
            Type     = 'Credentialed connection string'
            Severity = 'ERROR'
            Regex    = '(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp|mssql)://[^/\s:@]+:[^/\s@]+@[^/\s]+'
        },
        [pscustomobject]@{
            Type     = 'Basic authorization header'
            Severity = 'ERROR'
            Regex    = '(?i)\bAuthorization\s*:\s*Basic\s+[A-Za-z0-9+/=]{16,}'
        },
        [pscustomobject]@{
            Type     = 'npm auth token'
            Severity = 'ERROR'
            Regex    = '(?i)_authToken\s*=\s*[A-Za-z0-9._-]{12,}'
        }
    )
}

function Test-GitSecuritySensitiveFilename {
    param([Parameter(Mandatory = $true)][string]$Path)

    $name = [System.IO.Path]::GetFileName($Path)
    $normalized = $Path.Replace('\', '/')
    if ($name -match '(?i)^\.env$') { return 'environment file' }
    if ($name -match '(?i)^\.env\.(?!example$|sample$|template$|dist$)') { return 'environment file' }
    if ($name -match '(?i)^(?:id_rsa|id_dsa|id_ecdsa|id_ed25519)$') { return 'SSH private key file' }
    if ($name -match '(?i)\.(?:pem|p12|pfx|key)$') { return 'private key or certificate file' }
    if ($name -match '(?i)^(?:credentials|application_default_credentials)\.json$') { return 'credential file' }
    if ($name -match '(?i)^(?:\.npmrc|\.pypirc|\.netrc|\.aws/credentials)$') { return 'credential configuration file' }
    if ($normalized -match '(?i)(^|/)\.aws/credentials$') { return 'AWS credential file' }
    return $null
}

function Find-GitSecuritySecretFindings {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$Staged
    )

    $patterns = @(Get-GitSecurityContentPatterns)
    $files = @(Get-GitSecurityScanFiles -RepoRoot $RepoRoot -Staged:$Staged)
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $locations = @{}
    $scanned = 0

    foreach ($path in $files) {
        if (Test-GitSecuritySkippedPath $path) {
            continue
        }

        $filenameRisk = Test-GitSecuritySensitiveFilename $path
        if (-not [string]::IsNullOrWhiteSpace($filenameRisk)) {
            $findings.Add((New-GitSecurityFinding 'ERROR' "Sensitive file ($filenameRisk)" $path 0 '' 'This credential-bearing filename should not be committed.'))
            $locations["$path`:0"] = $true
        }

        $content = Get-GitSecurityFileContent -RepoRoot $RepoRoot -Path $path -Staged:$Staged
        if ($null -eq $content) {
            continue
        }
        $scanned++

        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($content, $pattern.Regex)) {
                $lineNumber = Get-GitSecurityLineNumber -Content $content -Index $match.Index
                $key = "$path`:$lineNumber"
                if ($locations.ContainsKey($key)) {
                    continue
                }
                $locations[$key] = $true
                $findings.Add((New-GitSecurityFinding $pattern.Severity $pattern.Type $path $lineNumber (Get-GitSecurityMaskedValue $match.Value) ''))
            }
        }

        $assignmentRegex = '(?i)\b(?:api[_-]?key|secret|token|password|passwd|pwd|client[_-]?secret|access[_-]?key)\b\s*[:=]\s*[''"]?(?<value>[A-Za-z0-9_./+=-]{8,})'
        foreach ($match in [regex]::Matches($content, $assignmentRegex)) {
            $value = $match.Groups['value'].Value
            if (Test-GitSecurityPlaceholderValue $value) {
                continue
            }
            $lineNumber = Get-GitSecurityLineNumber -Content $content -Index $match.Index
            $key = "$path`:$lineNumber"
            if ($locations.ContainsKey($key)) {
                continue
            }
            $locations[$key] = $true
            $findings.Add((New-GitSecurityFinding 'WARN' 'Possible hard-coded credential' $path $lineNumber (Get-GitSecurityMaskedValue $value) 'Review whether this assignment contains a real secret.'))
        }
    }

    [pscustomobject]@{
        Findings = [object[]]$findings.ToArray()
        Files    = $files.Count
        Scanned  = $scanned
    }
}

function Read-GitSecurityWorkflowLines {
    param([string]$Content)

    return [object[]]@($Content -split "\r?\n")
}

function Find-GitSecurityWorkflowFindings {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $workflowDirectory = Join-Path (Join-Path $RepoRoot '.github') 'workflows'
    if (-not (Test-Path -LiteralPath $workflowDirectory -PathType Container)) {
        return [pscustomobject]@{ Findings = @(); Workflows = 0 }
    }

    $files = @(Get-ChildItem -LiteralPath $workflowDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.yml', '.yaml') } |
        Sort-Object Name)
    $findings = New-Object 'System.Collections.Generic.List[object]'

    foreach ($file in $files) {
        $relativePath = ".github/workflows/$($file.Name)"
        $content = [System.IO.File]::ReadAllText($file.FullName)
        $lines = @(Read-GitSecurityWorkflowLines $content)
        $workflow = [pscustomobject]@{
            Name     = $file.BaseName
            Path     = $relativePath
            FileName = $file.Name
            FullPath = $file.FullName
            Content  = $content
        }
        foreach ($errorText in @(Test-ActionWorkflowLocalWorkflow $workflow)) {
            $findings.Add((New-GitSecurityFinding 'ERROR' 'Invalid workflow' $relativePath 0 '' $errorText))
        }

        $hasPullRequestTarget = ($content -match '(?im)(?:^|\s)pull_request_target(?=\s*(?::|$|,|\]))')
        if ($hasPullRequestTarget) {
            $checkoutMatches = [regex]::Matches($content, '(?ms)uses:\s*actions/checkout@[^\r\n]*(?<body>(?:\r?\n[ \t]+.*){0,12})')
            foreach ($checkout in $checkoutMatches) {
                $body = $checkout.Groups['body'].Value
                if ($body -match '(?i)ref\s*:\s*\$\{\{\s*github\.(?:event\.pull_request\.head|head_ref)') {
                    $line = Get-GitSecurityLineNumber -Content $content -Index $checkout.Index
                    $findings.Add((New-GitSecurityFinding 'ERROR' 'pull_request_target checkout' $relativePath $line '' 'The workflow checks out untrusted pull request code with a privileged trigger.'))
                    break
                }
            }
        }

        $permissionsMatch = [regex]::Match($content, '(?m)^permissions\s*:\s*(?<value>[^\r\n#]+)')
        if (-not $permissionsMatch.Success) {
            $findings.Add((New-GitSecurityFinding 'WARN' 'Missing permissions' $relativePath 0 '' 'No top-level permissions block; the default token permissions may be broader than needed.'))
        }
        else {
            $permissionValue = $permissionsMatch.Groups['value'].Value.Trim()
            if ($permissionValue -match '(?i)write-all') {
                $line = Get-GitSecurityLineNumber -Content $content -Index $permissionsMatch.Index
                $findings.Add((New-GitSecurityFinding 'ERROR' 'write-all permissions' $relativePath $line '' 'permissions: write-all grants every available write scope.'))
            }
        }

        if ($hasPullRequestTarget -and $content -match '(?i)permissions\s*:\s*(?:\r?\n\s+[^\r\n]*write|write-all)') {
            $line = Get-GitSecurityLineNumber -Content $content -Index ([regex]::Match($content, '(?i)permissions\s*:').Index)
            $findings.Add((New-GitSecurityFinding 'ERROR' 'Privileged pull_request_target' $relativePath $line '' 'A pull_request_target workflow has write permissions; verify every checkout and script is trusted.'))
        }

        if ($content -match '(?m)^\s*secrets\s*:\s*inherit\s*$') {
            $index = [regex]::Match($content, '(?m)^\s*secrets\s*:\s*inherit\s*$').Index
            $line = Get-GitSecurityLineNumber -Content $content -Index $index
            $findings.Add((New-GitSecurityFinding 'WARN' 'Inherited secrets' $relativePath $line '' 'secrets: inherit exposes every caller secret to the called workflow.'))
        }

        if ($content -match '(?i)(?:curl|wget)[^\r\n|]*\|\s*(?:ba|z|k)?sh\b') {
            $index = [regex]::Match($content, '(?i)(?:curl|wget)[^\r\n|]*\|\s*(?:ba|z|k)?sh\b').Index
            $line = Get-GitSecurityLineNumber -Content $content -Index $index
            $findings.Add((New-GitSecurityFinding 'WARN' 'Remote script execution' $relativePath $line '' 'Piping a downloaded script directly to a shell is not integrity-checked.'))
        }

        $runIndent = -1
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = [string]$lines[$lineIndex]
            $runMatch = [regex]::Match($line, '^(?<indent>\s*)(?:-\s+)?run\s*:\s*(?<inline>.*)$')
            if ($runMatch.Success) {
                $runIndent = $runMatch.Groups['indent'].Value.Length
                $inline = $runMatch.Groups['inline'].Value
                if ($inline -match '\$\{\{\s*github\.event') {
                    $findings.Add((New-GitSecurityFinding 'ERROR' 'Expression injection' $relativePath ($lineIndex + 1) '' 'Untrusted github.event data is interpolated directly into a run command.'))
                }
                continue
            }
            if ($runIndent -lt 0) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $indent = $line.Length - $line.TrimStart().Length
            if ($indent -le $runIndent -and $line.TrimStart() -notmatch '^#') {
                $runIndent = -1
                continue
            }
            if ($line -match '\$\{\{\s*github\.event') {
                $findings.Add((New-GitSecurityFinding 'ERROR' 'Expression injection' $relativePath ($lineIndex + 1) '' 'Untrusted github.event data is interpolated directly into a run command.'))
            }
            elseif ($line -match '\$\{\{\s*(?:github\.head_ref|inputs\.)') {
                $findings.Add((New-GitSecurityFinding 'WARN' 'Expression in run command' $relativePath ($lineIndex + 1) '' 'Verify this expression cannot contain attacker-controlled shell syntax.'))
            }
        }

        foreach ($actionMatch in [regex]::Matches($content, '(?m)^\s*(?:-\s*)?uses:\s*(?<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(?<ref>[^\s#]+)')) {
            $action = $actionMatch.Groups['action'].Value
            $ref = $actionMatch.Groups['ref'].Value
            if ($ref -notmatch '^[0-9a-fA-F]{40}$') {
                $line = Get-GitSecurityLineNumber -Content $content -Index $actionMatch.Index
                $findings.Add((New-GitSecurityFinding 'WARN' 'Unpinned action' $relativePath $line '' "Action $action is pinned to '$ref' instead of a full commit SHA."))
            }
        }
    }

    [pscustomobject]@{
        Findings  = [object[]]$findings.ToArray()
        Workflows = $files.Count
    }
}

function Write-GitSecurityFindings {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$Title
    )

    if ($Findings.Count -eq 0) {
        Write-Output "${Title}: no findings."
        return
    }
    Write-Output "${Title}:"
    foreach ($finding in $Findings) {
        $location = $finding.Path
        if ($finding.Line -gt 0) {
            $location = "$location`:$($finding.Line)"
        }
        $line = '  [{0}] {1} - {2}' -f $finding.Severity, $location, $finding.Type
        if (-not [string]::IsNullOrWhiteSpace($finding.Masked)) {
            $line += " ($($finding.Masked))"
        }
        if (-not [string]::IsNullOrWhiteSpace($finding.Message)) {
            $line += ": $($finding.Message)"
        }
        Write-Output $line
    }
}

function Invoke-GitSecurityCheck {
    param([string[]]$Arguments)

    if (@($Arguments) -contains '-h' -or @($Arguments) -contains '--help') {
        Show-GitSecurityCheckUsage
        return
    }
    $options = ConvertTo-ActionWorkflowOptions -Arguments $Arguments `
        -ValueOptions @{} `
        -SwitchOptions @{
            '--staged' = 'Staged'
            '--strict' = 'Strict'
            '--secrets-only' = 'SecretsOnly'
            '--workflows-only' = 'WorkflowsOnly'
        }
    if ($options.ContainsKey('SecretsOnly') -and $options.ContainsKey('WorkflowsOnly')) {
        throw '--secrets-only and --workflows-only cannot be used together.'
    }

    $root = Get-GitCommandRepoRoot
    $info = Get-GitCommandRepoInfo -RepoRoot $root
    $secretFindings = @()
    $workflowFindings = @()
    $secretMeta = [pscustomobject]@{ Findings = @(); Files = 0; Scanned = 0 }
    $workflowMeta = [pscustomobject]@{ Findings = @(); Workflows = 0 }

    if (-not $options.ContainsKey('WorkflowsOnly')) {
        $secretMeta = Find-GitSecuritySecretFindings -RepoRoot $root -Staged:($options.ContainsKey('Staged'))
        $secretFindings = @($secretMeta.Findings)
    }
    if (-not $options.ContainsKey('SecretsOnly')) {
        $workflowMeta = Find-GitSecurityWorkflowFindings -RepoRoot $root
        $workflowFindings = @($workflowMeta.Findings)
    }

    $allFindings = @($secretFindings + $workflowFindings)
    $errors = @($allFindings | Where-Object { $_.Severity -eq 'ERROR' })
    $warnings = @($allFindings | Where-Object { $_.Severity -eq 'WARN' })

    Write-Output "Security check: $($info.RepoRoot)"
    if ($options.ContainsKey('Staged')) {
        Write-Output 'Source: staged content'
    }
    else {
        Write-Output 'Source: working tree (tracked and untracked files)'
    }
    Write-Output ''

    if (-not $options.ContainsKey('WorkflowsOnly')) {
        Write-GitSecurityFindings -Findings $secretFindings -Title "Credentials ($($secretMeta.Scanned) of $($secretMeta.Files) files scanned)"
    }
    if (-not $options.ContainsKey('SecretsOnly')) {
        Write-GitSecurityFindings -Findings $workflowFindings -Title "Workflows ($($workflowMeta.Workflows) files scanned)"
    }

    Write-Output ''
    Write-Output "Summary: $($errors.Count) error(s), $($warnings.Count) warning(s)."
    if ($errors.Count -gt 0 -or ($options.ContainsKey('Strict') -and $warnings.Count -gt 0)) {
        Write-Output 'Security check failed.'
        $script:ExitCode = 1
        return
    }
    if ($warnings.Count -gt 0) {
        Write-Output 'Security check completed with warnings.'
    }
    else {
        Write-Output 'Security check passed.'
    }
    $script:ExitCode = 0
}
