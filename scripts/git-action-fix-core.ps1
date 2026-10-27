$ErrorActionPreference = 'Continue'

$script:ActionFixMaxLogCharacters = 2000000
$script:ActionFixMaxFileBytes = 5242880

$script:ActionFixSensitiveSegmentPattern = '^(?i:\.git|\.ssh|\.aws|\.azure|\.gnupg|\.kube|secrets?)$'
$script:ActionFixSensitiveLeafPattern = '^(?i:(?:\.env(?:\..*)?|\.npmrc|\.pypirc|\.git-credentials|credentials|secrets?|id_rsa(?:\..*)?|id_dsa(?:\..*)?|id_ecdsa(?:\..*)?|id_ed25519(?:\..*)?))$'
$script:ActionFixSensitiveExtensionPattern = '\.(?i:pem|key|pfx|p12|kdbx|jks|keystore|ppk)$'

$script:ActionFixCredentialPatterns = @(
    '\bgh[pousr]_[A-Za-z0-9]{20,}\b',
    '\bgithub_pat_[A-Za-z0-9_]{20,}\b',
    '\bAKIA[0-9A-Z]{16}\b',
    '\bxox[baprs]-[A-Za-z0-9-]{10,}\b',
    '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'
)

$script:ActionFixAuthPatterns = @(
    '(?i)\bbad credentials\b',
    '(?i)\bauthentication failed\b',
    '(?i)permission denied \(publickey\)',
    '(?i)resource not accessible by integration',
    '(?i)\bnot logged in\b',
    '(?i)could not read Username',
    '(?i)invalid username or password',
    '(?i)\b401 Unauthorized\b',
    '(?i)Input required and not supplied:[^\r\n]*(?:token|secret|password)',
    '(?i)\b(?:missing|no such) (?:secret|credential|token)\b',
    '(?i)\b(?:secret|token)\b[^\r\n]{0,40}\b(?:not found|not set|is required)\b'
)

$script:ActionFixTransientPatterns = @(
    '(?i)\bETIMEDOUT\b',
    '(?i)\bECONNRESET\b',
    '(?i)\bEAI_AGAIN\b',
    '(?i)\bENETUNREACH\b',
    '(?i)Temporary failure in name resolution',
    '(?i)Could not resolve host',
    '(?i)Connection reset by peer',
    '(?i)TLS handshake timeout',
    '(?i)The operation timed out',
    '(?i)timed out after \d+',
    '(?i)Remote end hung up unexpectedly',
    '(?i)\bRPC failed\b',
    '(?i)HTTP (?:429|500|502|503|504)\b',
    '(?i)\brate limit exceeded\b'
)

$script:ActionFixModulePackageMap = @{
    'yaml'      = 'PyYAML'
    'pil'       = 'Pillow'
    'cv2'       = 'opencv-python'
    'sklearn'   = 'scikit-learn'
    'bs4'       = 'beautifulsoup4'
    'dotenv'    = 'python-dotenv'
    'jwt'       = 'PyJWT'
    'github'    = 'PyGithub'
    'dateutil'  = 'python-dateutil'
    'psycopg2'  = 'psycopg2-binary'
    'crypto'    = 'pycryptodome'
    'requests'  = 'requests'
    'numpy'     = 'numpy'
    'pandas'    = 'pandas'
    'pytest'    = 'pytest'
    'sqlalchemy' = 'SQLAlchemy'
    'flask'     = 'Flask'
    'django'    = 'Django'
    'redis'     = 'redis'
    'pymongo'   = 'pymongo'
    'boto3'     = 'boto3'
    'grpc'      = 'grpcio'
    'pydantic'  = 'pydantic'
    'httpx'     = 'httpx'
    'aiohttp'   = 'aiohttp'
    'tabulate'  = 'tabulate'
    'rich'      = 'rich'
    'click'     = 'click'
}

function Invoke-ActionFixGit {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & git -C $Context.RepoRoot --no-optional-locks @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }

        $result = [pscustomobject]@{
            ExitCode = $exitCode
            Output   = [string[]]@($output | ForEach-Object { [string]$_ })
            Error    = $stderr
        }

        if ($exitCode -ne 0 -and -not $AllowFailure) {
            $detail = (@($result.Output + @($stderr)) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
            throw "git $($Arguments -join ' ') failed.`n$detail"
        }

        return $result
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ActionFixSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Protect-ActionFixSensitiveText {
    param([string]$Text)

    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) {
        return ''
    }

    $value = [regex]::Replace($value, "`e\][^\x07]*(?:\x07|$)", '')
    $value = [regex]::Replace($value, "`e\[[0-?]*[ -/]*[@-~]", '')
    $value = [regex]::Replace($value, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')

    $replacements = @(
        @{ Pattern = '(?i)(https?://)[^/\s:@]+:[^@\s]+@'; Replacement = '$1[REDACTED]@' },
        @{ Pattern = '(?i)(Authorization\s*:\s*)[^\r\n]+'; Replacement = '$1[REDACTED]' },
        @{ Pattern = '(?i)\b(gh[pousr]_[A-Za-z0-9]{20,})\b'; Replacement = '[REDACTED]' },
        @{ Pattern = '(?i)\b(github_pat_[A-Za-z0-9_]{20,})\b'; Replacement = '[REDACTED]' },
        @{ Pattern = '(?i)\b(AKIA[0-9A-Z]{16})\b'; Replacement = '[REDACTED]' },
        @{ Pattern = '(?i)\b(xox[baprs]-[A-Za-z0-9-]{10,})\b'; Replacement = '[REDACTED]' },
        @{ Pattern = '(?i)(-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----)'; Replacement = '[REDACTED]' },
        @{ Pattern = '(?i)\b(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})\b'; Replacement = '[REDACTED]' },
        @{ Pattern = '(?i)\b(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*[^\s"'']+'; Replacement = '$1=[REDACTED]' },
        @{ Pattern = '(?i)(::add-mask::)[^\r\n]+'; Replacement = '$1[REDACTED]' }
    )

    foreach ($replacement in $replacements) {
        $value = [regex]::Replace($value, $replacement.Pattern, $replacement.Replacement)
    }
    return $value
}

function Test-ActionFixCredentialLeak {
    param([string]$LogText)

    foreach ($pattern in $script:ActionFixCredentialPatterns) {
        if ([regex]::IsMatch([string]$LogText, $pattern)) {
            return $true
        }
    }
    return $false
}

function Test-ActionFixAnyPattern {
    param(
        [string]$Text,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ([regex]::IsMatch([string]$Text, $pattern)) {
            return $true
        }
    }
    return $false
}

function Get-ActionFixEvidence {
    param(
        [string]$LogText,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [int]$Maximum = 4
    )

    $evidence = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ([string]$LogText -split "\r?\n")) {
        if ($line -notmatch $Pattern) {
            continue
        }
        $clean = (Protect-ActionFixSensitiveText $line).Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) {
            continue
        }
        if ($clean.Length -gt 260) {
            $clean = $clean.Substring(0, 257) + '...'
        }
        if (-not $evidence.Contains($clean)) {
            $evidence.Add($clean)
        }
        if ($evidence.Count -ge $Maximum) {
            break
        }
    }
    return [object[]]$evidence.ToArray()
}

function Get-ActionFixDiagnosticEvidence {
    param([string]$LogText)

    $evidence = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ([string]$LogText -split "\r?\n")) {
        if ($line -notmatch '(?i)\b(?:error|failed|failure|exception|fatal|assertion|exit code)\b') {
            continue
        }
        $clean = (Protect-ActionFixSensitiveText $line).Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) {
            continue
        }
        if ($clean.Length -gt 260) {
            $clean = $clean.Substring(0, 257) + '...'
        }
        if (-not $evidence.Contains($clean)) {
            $evidence.Add($clean)
        }
        if ($evidence.Count -ge 5) {
            break
        }
    }
    return [object[]]$evidence.ToArray()
}

function Assert-ActionFixSafeRelativePath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $normalized = $RelativePath.Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'target path is empty.'
    }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $normalized.Contains(':')) {
        throw "target path '$RelativePath' must be repository-relative."
    }

    $segments = @($normalized -split '/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "target path '$RelativePath' is not a safe repository-relative path."
        }
        if ($segment -match $script:ActionFixSensitiveSegmentPattern) {
            throw "target path '$RelativePath' is a protected sensitive location."
        }
    }

    $leaf = $segments[$segments.Count - 1]
    if ($leaf -match $script:ActionFixSensitiveLeafPattern -or $leaf -match $script:ActionFixSensitiveExtensionPattern) {
        throw "target path '$RelativePath' looks like a secret or credential file and will not be modified."
    }

    $root = [System.IO.Path]::GetFullPath($Context.RepoRoot).TrimEnd([char]'\')
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root ($normalized.Replace('/', '\'))))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "target path '$RelativePath' escapes the repository root."
    }

    return [pscustomobject]@{
        RelativePath = $normalized
        FullPath     = $fullPath
    }
}

function Read-ActionFixTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt $script:ActionFixMaxFileBytes) {
        throw "file '$Path' is too large to edit safely."
    }

    $offset = 0
    $encoding = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true)
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true)
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true)
        $offset = 2
    }
    else {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($true, $true)
        try {
            $null = $strictUtf8.GetString($bytes)
            $encoding = [System.Text.UTF8Encoding]::new($false)
        }
        catch {
            $encoding = [System.Text.Encoding]::Default
        }
    }

    $content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $newLine = "`n"
    if ($content.Contains("`r`n")) {
        $newLine = "`r`n"
    }
    elseif ($content.Contains("`n")) {
        $newLine = "`n"
    }
    elseif ($content.Contains("`r")) {
        $newLine = "`r"
    }

    return [pscustomobject]@{
        FullPath = $Path
        Bytes    = $bytes
        Content  = $content
        Encoding = $encoding
        Preamble = [byte[]]$encoding.GetPreamble()
        NewLine  = $newLine
        Hash     = Get-ActionFixSha256 $bytes
    }
}

function Write-ActionFixTextFile {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $body = $Target.Encoding.GetBytes($Content)
    $preamble = [byte[]]$Target.Preamble
    $bytes = New-Object 'System.Byte[]' ($preamble.Length + $body.Length)
    if ($preamble.Length -gt 0) {
        [System.Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    }
    [System.Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    [System.IO.File]::WriteAllBytes($Target.FullPath, $bytes)
}

function Get-ActionFixSafeTarget {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $safePath = Assert-ActionFixSafeRelativePath -Context $Context -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $safePath.FullPath -PathType Leaf)) {
        throw "target file '$($safePath.RelativePath)' does not exist."
    }

    $item = Get-Item -LiteralPath $safePath.FullPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "target file '$($safePath.RelativePath)' is a symbolic link or reparse point and will not be modified."
    }
    if ($item.Length -gt $script:ActionFixMaxFileBytes) {
        throw "target file '$($safePath.RelativePath)' is too large to edit safely."
    }

    $tracked = Invoke-ActionFixGit -Context $Context -Arguments @('ls-files', '--error-unmatch', '--', $safePath.RelativePath) -AllowFailure
    if ($tracked.ExitCode -ne 0 -or @($tracked.Output).Count -eq 0) {
        throw "target file '$($safePath.RelativePath)' is not tracked by Git."
    }

    $status = Invoke-ActionFixGit -Context $Context -Arguments @('status', '--porcelain=v1', '--untracked-files=all', '--', $safePath.RelativePath)
    if (@($status.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
        throw "target file '$($safePath.RelativePath)' already has uncommitted changes."
    }

    $target = Read-ActionFixTextFile $safePath.FullPath
    $target | Add-Member -NotePropertyName RelativePath -NotePropertyValue $safePath.RelativePath
    return $target
}

function Get-ActionFixNewContentLine {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Line
    )

    $newLine = [string]$Target.NewLine
    if ($Target.Content.Length -eq 0) {
        return $Line + $newLine
    }
    if ($Target.Content.EndsWith($newLine, [System.StringComparison]::Ordinal)) {
        return $Target.Content + $Line + $newLine
    }
    return $Target.Content + $newLine + $Line + $newLine
}

function New-ActionFixAppendProposal {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][string]$Summary,
        [Parameter(Mandatory = $true)][string]$CommitTitle
    )

    if ($Line -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw 'the proposed dependency name is not valid.'
    }

    return [pscustomobject]@{
        Kind         = 'Append'
        Target       = $Target
        File         = $Target.RelativePath
        OriginalHash = $Target.Hash
        NewContent   = Get-ActionFixNewContentLine -Target $Target -Line $Line
        DiffLines    = [string[]]@("+ $Line")
        Summary      = $Summary
        CommitTitle  = $CommitTitle
    }
}

function New-ActionFixReplaceProposal {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$OldText,
        [Parameter(Mandatory = $true)][string]$NewText,
        [Parameter(Mandatory = $true)][string]$Summary,
        [Parameter(Mandatory = $true)][string]$CommitTitle
    )

    $index = $Target.Content.IndexOf($OldText, [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        throw 'the expected existing text was not found.'
    }
    $second = $Target.Content.IndexOf($OldText, $index + $OldText.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) {
        throw 'the expected existing text occurs more than once.'
    }

    $newContent = $Target.Content.Substring(0, $index) + $NewText + $Target.Content.Substring($index + $OldText.Length)
    return [pscustomobject]@{
        Kind         = 'Replace'
        Target       = $Target
        File         = $Target.RelativePath
        OriginalHash = $Target.Hash
        NewContent   = $newContent
        DiffLines    = [string[]]@("- $OldText", "+ $NewText")
        Summary      = $Summary
        CommitTitle  = $CommitTitle
    }
}

function Set-ActionFixProposal {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Proposal
    )

    $current = Get-ActionFixSafeTarget -Context $Context -RelativePath $Proposal.File
    if ($current.Hash -cne $Proposal.OriginalHash) {
        throw "target file '$($Proposal.File)' changed after the proposal was created; refusing to overwrite it."
    }

    try {
        Write-ActionFixTextFile -Target $current -Content $Proposal.NewContent
    }
    catch {
        try {
            [System.IO.File]::WriteAllBytes($current.FullPath, $current.Bytes)
        }
        catch {
        }
        throw "could not write '$($Proposal.File)': $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        File          = $Proposal.File
        FullPath      = $current.FullPath
        OriginalBytes = [byte[]]$current.Bytes
    }
}

function Undo-ActionFixProposal {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Rollback
    )

    [System.IO.File]::WriteAllBytes($Rollback.FullPath, $Rollback.OriginalBytes)
    $null = Invoke-ActionFixGit -Context $Context -Arguments @('reset', '--quiet', '--', $Rollback.File) -AllowFailure
}

function Assert-ActionFixEditReady {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run
    )

    if ($Context.Branch -cne [string]$Run.headBranch) {
        throw "run '$($Run.databaseId)' belongs to branch '$($Run.headBranch)', but the current branch is '$($Context.Branch)'. Check out the failed branch before applying an automated fix."
    }

    $headResult = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', 'HEAD')
    $head = (($headResult.Output -join '').Trim())
    if ($head -cne [string]$Run.headSha) {
        throw "local HEAD '$head' does not match the failed run commit '$($Run.headSha)'. Check out the exact failed commit before applying an automated fix."
    }

    $status = Invoke-ActionFixGit -Context $Context -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    $changed = @($status.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($changed.Count -gt 0) {
        $sample = @($changed | Select-Object -First 5) -join '; '
        throw "the working tree is not clean. Commit or stash all changes before applying an automated fix. Found: $sample"
    }

    $remoteRef = "refs/remotes/origin/$($Context.Branch)"
    $remoteResult = Invoke-ActionFixGit -Context $Context -Arguments @('rev-parse', '--verify', '--quiet', $remoteRef) -AllowFailure
    if ($remoteResult.ExitCode -ne 0) {
        throw "origin/$($Context.Branch) is not available locally. Fetch the branch and ensure it is synchronized before applying an automated fix."
    }
    $remoteHead = (($remoteResult.Output -join '').Trim())
    if ($remoteHead -cne $head) {
        throw "local branch '$($Context.Branch)' is not synchronized with origin/$($Context.Branch). Pull or push your branch before applying an automated fix."
    }

    return [pscustomobject]@{
        Head      = $head
        RemoteRef = $remoteRef
        RemoteHead = $remoteHead
    }
}

function Get-ActionFixFailedJobs {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run
    )

    $failedConclusions = @('failure', 'timed_out', 'action_required', 'startup_failure', 'cancelled')
    $jobs = @(Get-ActionWorkflowJobs $Context $Run)
    return [object[]]@($jobs | Where-Object { [string]$_.conclusion -in $failedConclusions })
}

function Get-ActionFixLogs {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run
    )

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $failedResult = Invoke-ActionWorkflowGh @(
        'run', 'view', [string]$Run.databaseId,
        '--repo', $Context.RepoSpec,
        '--log-failed'
    )

    $text = ''
    $mode = 'failed steps'
    if ($failedResult.ExitCode -eq 0) {
        $text = (@($failedResult.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
    else {
        $warnings.Add("could not retrieve failed-step logs: $(Format-ActionWorkflowFailure $failedResult)")
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        $fullResult = Invoke-ActionWorkflowGh @(
            'run', 'view', [string]$Run.databaseId,
            '--repo', $Context.RepoSpec,
            '--log'
        )
        if ($fullResult.ExitCode -eq 0) {
            $text = (@($fullResult.Output | ForEach-Object { [string]$_ }) -join "`n").Trim()
            $mode = 'full logs'
        }
        else {
            $warnings.Add("could not retrieve full run logs: $(Format-ActionWorkflowFailure $fullResult)")
        }
    }

    if ($text.Length -gt $script:ActionFixMaxLogCharacters) {
        $text = $text.Substring($text.Length - $script:ActionFixMaxLogCharacters)
        $warnings.Add("log output was truncated to the last $($script:ActionFixMaxLogCharacters) characters for analysis.")
    }

    return [pscustomobject]@{
        Text     = $text
        Mode     = $mode
        Warnings = [object[]]$warnings.ToArray()
        Lines    = @($text -split "\r?\n").Count
    }
}

function Get-ActionFixLocalWorkflowForRun {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run
    )

    $workflows = @(Get-ActionWorkflowLocalWorkflowFiles $Context)
    $matches = @($workflows | Where-Object { [string]$_.Name -ieq [string]$Run.workflowName })
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function Get-ActionFixWorkflowInstallPattern {
    param([Parameter(Mandatory = $true)][string]$RequirementsPath)

    $escaped = [regex]::Escape($RequirementsPath)
    return '(?im)^[ \t]*(?:-[ \t]+)?(?:run[ \t]*:[ \t]*)?(?:sudo[ \t]+)?(?:python(?:\d+(?:\.\d+)?)?[ \t]+-m[ \t]+)?pip(?:3)?[ \t]+install\b[^\r\n]*?(?:-r|--requirement)(?:[ \t]+|=)[ \t]*["'']?(?:\./)?' + $escaped + '(?![\w.-])'
}

function Test-ActionFixRequirementsContainsPackage {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Package
    )

    $normalizedPackage = $Package.Replace('_', '-').ToLowerInvariant()
    foreach ($line in ($Target.Content -split "\r?\n")) {
        $candidate = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.StartsWith('#')) {
            continue
        }
        if ($candidate.StartsWith('-')) {
            continue
        }
        $match = [regex]::Match($candidate, '^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)')
        if (-not $match.Success) {
            continue
        }
        $normalized = $match.Groups['name'].Value.Replace('_', '-').ToLowerInvariant()
        if ($normalized -eq $normalizedPackage) {
            return $true
        }
    }
    return $false
}

function Resolve-ActionFixRequirementsTarget {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][string]$Package
    )

    $files = @(Get-ChildItem -LiteralPath $Context.RepoRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^requirements(?:[-_.][A-Za-z0-9._-]+)?\.txt$' } |
        Sort-Object @{ Expression = { if ($_.Name -ieq 'requirements.txt') { 0 } else { 1 } } }, Name)

    if ($files.Count -eq 0) {
        throw 'no requirements file was found in the repository root.'
    }

    $referenced = New-Object 'System.Collections.Generic.List[object]'
    $patternCache = @{}
    foreach ($file in $files) {
        $relative = $file.Name
        $patternCache[$relative] = Get-ActionFixWorkflowInstallPattern $relative
        if ([string]$Workflow.Content -match $patternCache[$relative]) {
            $referenced.Add([pscustomobject]@{ File = $file; RelativePath = $relative })
        }
    }

    if ($referenced.Count -eq 0) {
        throw "workflow '$($Workflow.Name)' does not install a root requirements file, so adding a package would not affect CI."
    }

    $chosen = $null
    if ($referenced.Count -eq 1) {
        $chosen = $referenced[0]
    }
    else {
        $preferred = @($referenced | Where-Object { $_.RelativePath -ieq 'requirements.txt' })
        if ($preferred.Count -eq 1) {
            $chosen = $preferred[0]
        }
        else {
            $names = @($referenced | ForEach-Object { $_.RelativePath }) -join ', '
            throw "multiple requirements files are installed by the workflow ($names); choose one manually."
        }
    }

    $target = Get-ActionFixSafeTarget -Context $Context -RelativePath $chosen.RelativePath
    if (Test-ActionFixRequirementsContainsPackage -Target $target -Package $Package) {
        throw "package '$Package' is already listed in '$($chosen.RelativePath)', so the dependency fix is not applicable."
    }

    return $target
}

function Get-ActionFixNodeRequiredMajor {
    param([string]$LogText)

    $patterns = @(
        '(?i)Expected version\s*["'']?[^0-9\r\n"'']{0,20}(?<major>\d{1,2})',
        '(?i)Required:\s*\{\s*["'']node["'']\s*:\s*["''][^0-9\r\n"'']{0,20}(?<major>\d{1,2})'
    )
    foreach ($pattern in $patterns) {
        $match = [regex]::Match([string]$LogText, $pattern)
        if ($match.Success) {
            $major = [int]$match.Groups['major'].Value
            if ($major -ge 12 -and $major -le 40) {
                return $major
            }
        }
    }
    return $null
}

function New-ActionFixNodeProposal {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][int]$RequiredMajor
    )

    $target = Get-ActionFixSafeTarget -Context $Context -RelativePath $Workflow.Path
    $lineRegex = [regex]'(?m)^(?<prefix>[ \t]*node-version[ \t]*:[ \t]*)(?:(?<quote>["''])(?<quoted>[^"'']+)\k<quote>|(?<plain>[^#\s]+))(?<suffix>[ \t]*(?:#.*)?)$'
    $matches = @($lineRegex.Matches($target.Content))
    if ($matches.Count -eq 0) {
        throw "workflow '$($Workflow.Path)' does not contain a node-version setting."
    }
    if ($matches.Count -gt 1) {
        throw "workflow '$($Workflow.Path)' contains multiple node-version settings."
    }

    $match = $matches[0]
    $quote = $match.Groups['quote'].Value
    $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    if ($value -match '\$\{\{') {
        throw "workflow '$($Workflow.Path)' uses a dynamic node-version expression."
    }

    $majorMatch = [regex]::Match($value, '^v?(?<major>\d{1,2})')
    if (-not $majorMatch.Success) {
        throw "could not parse the current node-version '$value'."
    }
    $currentMajor = [int]$majorMatch.Groups['major'].Value
    if ($currentMajor -ge $RequiredMajor) {
        throw "the workflow already uses Node.js $currentMajor, which satisfies the logged requirement."
    }

    $newLine = $match.Groups['prefix'].Value + $quote + [string]$RequiredMajor + $quote + $match.Groups['suffix'].Value
    $oldLine = $match.Value
    return New-ActionFixReplaceProposal -Target $target -OldText $oldLine -NewText $newLine `
        -Summary "Update the workflow Node.js version from $currentMajor to $RequiredMajor." `
        -CommitTitle "Fix CI: update Node.js to $RequiredMajor"
}

function Test-ActionFixMissingLockfileLog {
    param([string]$LogText)

    return ([regex]::IsMatch([string]$LogText, '(?i)npm ci\b[^\r\n]{0,120}(?:can only install|requires an existing|existing package-lock\.json)') -or
        [regex]::IsMatch([string]$LogText, '(?i)(?:can only install|requires an existing)[^\r\n]{0,120}package-lock\.json'))
}

function New-ActionFixNpmLockProposal {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Workflow
    )

    if (Test-Path -LiteralPath (Join-Path $Context.RepoRoot 'package-lock.json')) {
        throw 'package-lock.json exists locally, so replacing npm ci would not address the logged failure.'
    }

    $target = Get-ActionFixSafeTarget -Context $Context -RelativePath $Workflow.Path
    $linePattern = '(?im)^(?<line>[ \t]*(?:-[ \t]+)?(?:run[ \t]*:[ \t]*)?npm[ \t]+ci(?<rest>[^\r\n]*))(?<cr>\r?)$'
    $matches = @([regex]::Matches($target.Content, $linePattern))
    if ($matches.Count -eq 0) {
        throw "workflow '$($Workflow.Path)' does not contain an npm ci command line."
    }
    if ($matches.Count -gt 1) {
        throw "workflow '$($Workflow.Path)' contains multiple npm ci command lines."
    }

    $oldLine = $matches[0].Groups['line'].Value
    $commandMatches = [regex]::Matches($oldLine, '(?i)(?<![\w-])npm\s+ci(?![\w-])')
    if ($commandMatches.Count -ne 1) {
        throw "workflow '$($Workflow.Path)' contains an npm ci line that cannot be replaced safely."
    }
    $newLine = [regex]::Replace($oldLine, '(?i)(?<![\w-])npm\s+ci(?![\w-])', 'npm install')

    return New-ActionFixReplaceProposal -Target $target -OldText $oldLine -NewText $newLine `
        -Summary 'Use npm install because the workflow has no committed package-lock.json.' `
        -CommitTitle 'Fix CI: install npm dependencies without a lockfile'
}

function New-ActionFixFinding {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Confidence,
        [string]$Action,
        [string]$Explanation,
        [object[]]$Evidence,
        [object]$Proposal,
        [string]$File
    )

    return [pscustomobject]@{
        Id          = $Id
        Title       = $Title
        Confidence  = $Confidence
        Action      = $Action
        Explanation = $Explanation
        Evidence    = [object[]]@($Evidence)
        Proposal    = $Proposal
        File        = $File
    }
}

function Get-ActionFixDiagnosis {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Run,
        $Workflow,
        [string]$LogText
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $text = [string]$LogText

    if (Test-ActionFixCredentialLeak $text) {
        $findings.Add((New-ActionFixFinding -Id 'credential-leak' -Title 'Credential-like value appeared in logs' `
            -Confidence 'high' -Action 'Manual' `
            -Explanation 'A token, private key, or credential-like value was detected in the failed logs. Automated edits and retries are disabled. Revoke or rotate the value if it is real, then review secret masking before changing CI.' `
            -Evidence @('[REDACTED] credential-like value detected in logs')))
        return [pscustomobject]@{ Findings = [object[]]$findings.ToArray(); Selected = $findings[0] }
    }

    if (Test-ActionFixAnyPattern -Text $text -Patterns $script:ActionFixAuthPatterns) {
        $authEvidence = Get-ActionFixEvidence -LogText $text -Pattern '(?i)(?:bad credentials|authentication failed|permission denied|resource not accessible|not logged in|invalid username|401 Unauthorized|input required|missing secret|no such secret|not found|not set|is required)'
        $findings.Add((New-ActionFixFinding -Id 'authentication' -Title 'Authentication or secret configuration failure' `
            -Confidence 'high' -Action 'Manual' `
            -Explanation 'The run failed while authenticating or resolving a secret. Credentials and secret values are never modified or retried automatically. Check repository permissions, workflow token scopes, and secret names manually.' `
            -Evidence $authEvidence))
        return [pscustomobject]@{ Findings = [object[]]$findings.ToArray(); Selected = $findings[0] }
    }

    $modulePattern = '(?i)ModuleNotFoundError:\s+No module named\s+["'']?(?<module>[A-Za-z0-9_.-]+)'
    $modules = New-Object 'System.Collections.Generic.List[string]'
    foreach ($match in [regex]::Matches($text, $modulePattern)) {
        $module = $match.Groups['module'].Value
        if (-not $modules.Contains($module)) {
            $modules.Add($module)
        }
    }

    foreach ($module in $modules) {
        $topLevel = $module.Split('.')[0]
        $package = $script:ActionFixModulePackageMap[$topLevel.ToLowerInvariant()]
        $evidence = Get-ActionFixEvidence -LogText $text -Pattern '(?i)ModuleNotFoundError|No module named'
        if ([string]::IsNullOrWhiteSpace($package)) {
            $findings.Add((New-ActionFixFinding -Id "python-$topLevel" -Title "Missing Python module '$topLevel'" `
                -Confidence 'high' -Action 'Manual' `
                -Explanation "Python could not import '$module'. The module was not mapped to a trusted package name, so no dependency will be added automatically." `
                -Evidence $evidence))
            continue
        }

        if ($null -eq $Workflow) {
            $findings.Add((New-ActionFixFinding -Id "python-$topLevel" -Title "Missing Python module '$topLevel'" `
                -Confidence 'high' -Action 'Manual' `
                -Explanation "Python could not import '$module'. The failing workflow file could not be resolved locally, so the dependency installation cannot be verified safely." `
                -Evidence $evidence))
            continue
        }

        try {
            $target = Resolve-ActionFixRequirementsTarget -Context $Context -Workflow $Workflow -Package $package
            $proposal = New-ActionFixAppendProposal -Target $target -Line $package `
                -Summary "Add $package to $($target.RelativePath) because the workflow installs that file before running Python." `
                -CommitTitle "Fix CI: add $package dependency"
            $findings.Add((New-ActionFixFinding -Id "python-$topLevel" -Title "Missing Python dependency '$package'" `
                -Confidence 'high' -Action 'Edit' `
                -Explanation "The failed job imported '$module', but '$package' was not installed. The workflow installs $($target.RelativePath), so appending the package is a targeted dependency fix." `
                -Evidence $evidence -Proposal $proposal -File $target.RelativePath))
        }
        catch {
            $findings.Add((New-ActionFixFinding -Id "python-$topLevel" -Title "Missing Python dependency '$package'" `
                -Confidence 'high' -Action 'Manual' `
                -Explanation "Python could not import '$module'. No safe requirements-file edit is available: $($_.Exception.Message)" `
                -Evidence $evidence))
        }
    }

    if ([regex]::IsMatch($text, '(?i)(?:EBADENGINE|engine ["'']?node["'']? (?:is )?incompatible|Unsupported engine)')) {
        $evidence = Get-ActionFixEvidence -LogText $text -Pattern '(?i)EBADENGINE|Unsupported engine|engine ["'']?node|Expected version|Required:'
        $requiredMajor = Get-ActionFixNodeRequiredMajor $text
        if ($null -eq $requiredMajor) {
            $findings.Add((New-ActionFixFinding -Id 'node-engine' -Title 'Unsupported Node.js version' `
                -Confidence 'medium' -Action 'Manual' `
                -Explanation 'A dependency rejected the workflow Node.js version, but the required major version could not be parsed safely.' `
                -Evidence $evidence))
        }
        elseif ($null -eq $Workflow) {
            $findings.Add((New-ActionFixFinding -Id 'node-engine' -Title "Node.js $requiredMajor is required" `
                -Confidence 'high' -Action 'Manual' `
                -Explanation 'The run requires a newer Node.js major version, but the failing workflow file could not be resolved locally.' `
                -Evidence $evidence))
        }
        else {
            try {
                $proposal = New-ActionFixNodeProposal -Context $Context -Workflow $Workflow -RequiredMajor $requiredMajor
                $findings.Add((New-ActionFixFinding -Id 'node-engine' -Title "Node.js $requiredMajor is required" `
                    -Confidence 'high' -Action 'Edit' `
                    -Explanation "A dependency requires Node.js $requiredMajor, and the workflow pins an older major version. Updating the setup-node version aligns CI with the dependency." `
                    -Evidence $evidence -Proposal $proposal -File $proposal.File))
            }
            catch {
                $findings.Add((New-ActionFixFinding -Id 'node-engine' -Title "Node.js $requiredMajor is required" `
                    -Confidence 'high' -Action 'Manual' `
                    -Explanation "The run requires Node.js $requiredMajor, but no safe workflow edit is available: $($_.Exception.Message)" `
                    -Evidence $evidence))
            }
        }
    }

    if (Test-ActionFixMissingLockfileLog $text) {
        $evidence = Get-ActionFixEvidence -LogText $text -Pattern '(?i)npm ci|package-lock\.json'
        if ($null -eq $Workflow) {
            $findings.Add((New-ActionFixFinding -Id 'npm-lockfile' -Title 'npm ci cannot find a lockfile' `
                -Confidence 'high' -Action 'Manual' `
                -Explanation 'npm ci requires a committed package-lock.json, but the failing workflow file could not be resolved locally.' `
                -Evidence $evidence))
        }
        else {
            try {
                $proposal = New-ActionFixNpmLockProposal -Context $Context -Workflow $Workflow
                $findings.Add((New-ActionFixFinding -Id 'npm-lockfile' -Title 'npm ci cannot find a lockfile' `
                    -Confidence 'high' -Action 'Edit' `
                    -Explanation 'npm ci requires a committed package-lock.json. Replacing this one command with npm install lets CI install dependencies, but a lockfile should be committed later for reproducible builds.' `
                    -Evidence $evidence -Proposal $proposal -File $proposal.File))
            }
            catch {
                $findings.Add((New-ActionFixFinding -Id 'npm-lockfile' -Title 'npm ci cannot find a lockfile' `
                    -Confidence 'high' -Action 'Manual' `
                    -Explanation "npm ci requires a lockfile, but no safe workflow edit is available: $($_.Exception.Message)" `
                    -Evidence $evidence))
            }
        }
    }

    if (Test-ActionFixAnyPattern -Text $text -Patterns $script:ActionFixTransientPatterns) {
        $evidence = Get-ActionFixEvidence -LogText $text -Pattern '(?i)ETIMEDOUT|ECONNRESET|EAI_AGAIN|ENETUNREACH|Temporary failure|Could not resolve host|Connection reset|TLS handshake timeout|timed out|Remote end hung up|RPC failed|HTTP (?:429|500|502|503|504)|rate limit'
        $findings.Add((New-ActionFixFinding -Id 'transient' -Title 'Network or service failure' `
            -Confidence 'medium' -Action 'Retry' `
            -Explanation 'The logs show a transient network or service error rather than a code defect. A retry requires explicit approval and will be verified through the existing workflow engine; no files will be changed.' `
            -Evidence $evidence))
    }

    if ($findings.Count -eq 0) {
        $title = 'Unrecognized CI failure'
        if ([regex]::IsMatch($text, '(?i)AssertionError|\bFAILED\b|expected .* but')) {
            $title = 'Test or assertion failure'
        }
        elseif ([regex]::IsMatch($text, '(?i)SyntaxError|YAML|configuration|invalid workflow')) {
            $title = 'Configuration or syntax failure'
        }
        elseif ([string]::IsNullOrWhiteSpace($text)) {
            $title = 'No actionable logs were available'
        }
        $explanation = 'No safe automatic fix rule matched this failure. Review the failed job and fix the underlying issue manually; the command will not retry blindly.'
        if ([string]::IsNullOrWhiteSpace($text)) {
            $explanation = 'GitHub did not return usable failure logs. Review the run and failed jobs manually; the command will not edit files or retry blindly.'
        }
        $findings.Add((New-ActionFixFinding -Id 'manual' -Title $title -Confidence 'low' -Action 'Manual' `
            -Explanation $explanation -Evidence (Get-ActionFixDiagnosticEvidence $text)))
    }

    $selected = $findings | Where-Object { $_.Action -ceq 'Edit' } | Select-Object -First 1
    if ($null -eq $selected) {
        $selected = $findings | Where-Object { $_.Action -ceq 'Retry' } | Select-Object -First 1
    }
    if ($null -eq $selected) {
        $selected = $findings[0]
    }

    return [pscustomobject]@{
        Findings = [object[]]$findings.ToArray()
        Selected = $selected
    }
}

function Invoke-ActionFixWorkflowCommand {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $oldErrorAction = $ErrorActionPreference
    Push-Location -LiteralPath $Context.RepoRoot
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git action-workflow @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Text     = (@($output | ForEach-Object { [string]$_ }) -join "`n")
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 1
            Text     = $_.Exception.Message
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
        Pop-Location
    }
}

function Wait-ActionFixNewRun {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$OriginalRun,
        [Parameter(Mandatory = $true)][string]$HeadSha,
        [int]$Timeout = 120,
        [int]$Interval = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    $lastError = $null
    while ($true) {
        try {
            $runs = @(Get-ActionWorkflowRuns -Context $Context -Branch $Context.Branch -Limit 30)
            $matches = @($runs | Where-Object {
                [string]$_.headSha -ieq $HeadSha -and (
                    (-not [string]::IsNullOrWhiteSpace([string]$OriginalRun.workflowDatabaseId) -and
                        [string]$_.workflowDatabaseId -eq [string]$OriginalRun.workflowDatabaseId) -or
                    ([string]$_.workflowName -ieq [string]$OriginalRun.workflowName)
                )
            } | Sort-Object -Property createdAt -Descending)
            if ($matches.Count -gt 0) {
                return $matches[0]
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -le 0) {
            $suffix = ''
            if (-not [string]::IsNullOrWhiteSpace($lastError)) {
                $suffix = " Last GitHub error: $lastError"
            }
            throw "timed out after $Timeout second(s) waiting for a new workflow run for commit $HeadSha.$suffix"
        }
        $sleepSeconds = [int][Math]::Min($Interval, [Math]::Max(1, [Math]::Ceiling($remaining)))
        Start-Sleep -Seconds $sleepSeconds
    }
}

function Wait-ActionFixRerunStart {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$OriginalRun,
        [int]$Timeout = 120,
        [int]$Interval = 5
    )

    $originalAttempt = 0
    if ($null -ne $OriginalRun.attempt) {
        $originalAttempt = [int]$OriginalRun.attempt
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ($true) {
        $current = Get-ActionWorkflowRun $Context ([string]$OriginalRun.databaseId)
        $currentAttempt = 0
        if ($null -ne $current.attempt) {
            $currentAttempt = [int]$current.attempt
        }
        if ($currentAttempt -gt $originalAttempt -or [string]$current.status -ne 'completed') {
            return $current
        }

        $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -le 0) {
            throw "the retry request was accepted, but no new attempt appeared for run $($OriginalRun.databaseId) after $Timeout second(s)."
        }
        $sleepSeconds = [int][Math]::Min($Interval, [Math]::Max(1, [Math]::Ceiling($remaining)))
        Start-Sleep -Seconds $sleepSeconds
    }
}
