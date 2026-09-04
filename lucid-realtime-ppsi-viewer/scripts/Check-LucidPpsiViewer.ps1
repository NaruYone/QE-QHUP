[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$failures = 0
$warnings = 0

function Write-CheckResult {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')]
        [string]$Level,
        [string]$Message
    )

    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
    }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

Write-Host 'LUCID PPSI Viewer environment check' -ForegroundColor Cyan
Write-Host ("Project: {0}" -f $projectDir)

$requiredFiles = @(
    'lucid_ppsi_viewer.m',
    'ArenaLatestFrameWriter.exe',
    'PpsiSharedMemoryReader.dll',
    'ArenaNET_v140.dll',
    'Arena_v140.dll',
    'GenTL_LUCID_v140.dll'
)

foreach ($name in $requiredFiles) {
    $path = Join-Path $projectDir $name
    if (Test-Path -LiteralPath $path) {
        Write-CheckResult OK $name
    }
    else {
        Write-CheckResult FAIL ("Missing: {0}" -f $name)
        $failures++
    }
}

$uninstallRoots = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$arena = Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'Arena SDK' } |
    Select-Object -First 1
if ($arena) {
    Write-CheckResult OK ("Arena SDK {0}" -f $arena.DisplayVersion)
}
else {
    Write-CheckResult FAIL 'Arena SDK is not installed.'
    $failures++
}

$matlabCandidates = Get-ChildItem -LiteralPath 'C:\Program Files\MATLAB' -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'bin\matlab.exe' } |
    Where-Object { Test-Path -LiteralPath $_ }

if (-not $matlabCandidates) {
    Write-CheckResult FAIL 'MATLAB is not installed under C:\Program Files\MATLAB.'
    $failures++
}
else {
    $matlabExe = $matlabCandidates | Select-Object -First 1
    Write-CheckResult OK ("MATLAB found: {0}" -f $matlabExe)

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($currentIdentity -match '\\codexsandbox') {
        Write-CheckResult WARN ("MATLAB license check skipped for isolated account {0}. Run this script directly as CS13 to verify the user license." -f $currentIdentity)
        $warnings++
    }
    else {
        $prefDir = Join-Path $env:TEMP 'RealtimePPSI_MATLAB_pref'
        New-Item -ItemType Directory -Force -Path $prefDir | Out-Null
        $oldPrefDir = $env:MATLAB_PREFDIR
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $env:MATLAB_PREFDIR = $prefDir
            # MATLAB writes license failures to stderr. Capture them as diagnostic
            # output instead of letting PowerShell stop this checker prematurely.
            $ErrorActionPreference = 'Continue'
            $matlabOutput = & $matlabExe -batch "fprintf('MATLAB_OK=%d\n',1);" 2>&1
            $matlabExit = $LASTEXITCODE
        }
        finally {
            $env:MATLAB_PREFDIR = $oldPrefDir
            $ErrorActionPreference = $oldErrorActionPreference
        }

        if ($matlabExit -eq 0 -and ($matlabOutput -match 'MATLAB_OK=1')) {
            Write-CheckResult OK 'MATLAB license checkout succeeded.'
        }
        else {
            Write-CheckResult FAIL 'MATLAB license checkout failed. Activate MATLAB or configure the license server.'
            $failures++
            $matlabOutput | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
        }
    }
}

$bridge = Join-Path $projectDir 'ArenaLatestFrameWriter.exe'
if (Test-Path -LiteralPath $bridge) {
    Push-Location -LiteralPath $projectDir
    try {
        $deviceOutput = & $bridge --list 2>&1
        $bridgeExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($bridgeExit -ne 0) {
        Write-CheckResult FAIL ("Camera bridge failed with exit code {0}." -f $bridgeExit)
        $deviceOutput | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
        $failures++
    }
    elseif ($deviceOutput -match 'Devices:\s*0') {
        Write-CheckResult WARN 'No LUCID camera is detected. Check power/Ethernet/IP settings in ArenaView.'
        $warnings++
    }
    else {
        Write-CheckResult OK 'LUCID camera detected.'
        $deviceOutput | ForEach-Object { Write-Host $_ }
    }
}

Write-Host ''
Write-Host ("Summary: {0} failure(s), {1} warning(s)" -f $failures, $warnings)
if ($failures -gt 0) {
    exit 1
}
if ($warnings -gt 0) {
    exit 2
}
exit 0
