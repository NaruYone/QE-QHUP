[CmdletBinding()]
param(
    [string]$MatlabRelease = 'R2023b'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$matlabExe = "C:\Program Files\MATLAB\$MatlabRelease\bin\matlab.exe"
$bridgeExe = Join-Path $projectDir 'ArenaLatestFrameWriter.exe'
$mainFile = Join-Path $projectDir 'lucid_ppsi_viewer.m'

if (-not (Test-Path -LiteralPath $matlabExe)) {
    throw "MATLAB $MatlabRelease was not found: $matlabExe"
}
if (-not (Test-Path -LiteralPath $bridgeExe)) {
    throw "Camera bridge was not found: $bridgeExe"
}
if (-not (Test-Path -LiteralPath $mainFile)) {
    throw "MATLAB program was not found: $mainFile"
}

Push-Location -LiteralPath $projectDir
try {
    $deviceOutput = & $bridgeExe --list 2>&1
    $bridgeExit = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($bridgeExit -ne 0) {
    throw "Arena camera bridge failed: $($deviceOutput -join [Environment]::NewLine)"
}
if ($deviceOutput -match 'Devices:\s*0') {
    Write-Warning 'No camera is detected. ArenaView should see the camera before PPSI is started.'
}

$logFile = Join-Path $projectDir 'RealtimePPSI_matlab.log'
$startupCode = "try, lucid_ppsi_viewer; catch ME, disp(getReport(ME,'extended')); exit(1); end"

# Pass one explicitly quoted command line. Start-Process otherwise removes the
# grouping around the value following -r, and MATLAB may exit without running
# lucid_ppsi_viewer.
$argumentString = "-sd `"$projectDir`" -logfile `"$logFile`" -r `"$startupCode`""
$process = Start-Process -FilePath $matlabExe -ArgumentList $argumentString `
    -WorkingDirectory $projectDir -PassThru

Start-Sleep -Seconds 5
$process.Refresh()
if ($process.HasExited) {
    $details = ''
    if (Test-Path -LiteralPath $logFile) {
        $details = (Get-Content -LiteralPath $logFile -Tail 80) -join [Environment]::NewLine
    }
    throw "MATLAB exited during startup with code $($process.ExitCode).`nLog: $logFile`n$details"
}

Write-Host "Started LUCID PPSI Viewer with MATLAB $MatlabRelease."
Write-Host "MATLAB log: $logFile"
