[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$suites = @(
    'run-work-tests.ps1',
    'run-doctor-tests.ps1',
    'run-security-check-tests.ps1',
    'run-pr-flow-tests.ps1',
    'run-release-tests.ps1'
)

$failed = New-Object 'System.Collections.Generic.List[string]'

foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite
    Write-Output ''
    Write-Output "=== $suite ==="
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Output "MISSING  $path"
        $failed.Add($suite)
        continue
    }

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) {
        Write-Output ([string]$line)
    }
    if ($code -ne 0) {
        $failed.Add($suite)
    }
}

Write-Output ''
if ($failed.Count -gt 0) {
    Write-Output "Suites failed: $($failed -join ', ')"
    exit 1
}

Write-Output 'All suites passed.'
exit 0
