[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArenaNetDll,
    [string]$ArenaRuntimeDir = 'C:\Program Files\Lucid Vision Labs\Arena SDK\Win32Release'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$sourceDir = Join-Path $projectDir 'src'
$compiler = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "C# compiler was not found: $compiler"
}
if (-not (Test-Path -LiteralPath $ArenaNetDll)) {
    throw "ArenaNET assembly was not found: $ArenaNetDll"
}
if (-not (Test-Path -LiteralPath $ArenaRuntimeDir)) {
    throw "Arena SDK Win32 runtime directory was not found: $ArenaRuntimeDir"
}

$readerOutput = Join-Path $projectDir 'PpsiSharedMemoryReader.dll'
$bridgeOutput = Join-Path $projectDir 'ArenaLatestFrameWriter.exe'

& $compiler /nologo /target:library /platform:anycpu /optimize+ `
    "/out:$readerOutput" (Join-Path $sourceDir 'PpsiSharedMemoryReader.cs')
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to build PpsiSharedMemoryReader.dll.'
}

& $compiler /nologo /target:exe /platform:x86 /optimize+ `
    "/out:$bridgeOutput" "/reference:$ArenaNetDll" `
    (Join-Path $sourceDir 'ArenaLatestFrameWriter.cs')
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to build ArenaLatestFrameWriter.exe.'
}

Copy-Item -LiteralPath $ArenaNetDll -Destination $projectDir -Force

$runtimeFiles = @(
    'Arena_v140.dll',
    'GenTL_LUCID_v140.dll',
    'GCBase_MD_VC140_v3_1_LUCID.dll',
    'GenApi_MD_VC140_v3_1_LUCID.dll',
    'Log_MD_VC140_v3_1_LUCID.dll',
    'MathParser_MD_VC140_v3_1_LUCID.dll',
    'NodeMapData_MD_VC140_v3_1_LUCID.dll',
    'XmlParser_MD_VC140_v3_1_LUCID.dll',
    'lucidlog_v140.dll',
    'rply.dll',
    'CLAllSerial_MD_VC140_v3_1_LUCID.dll',
    'CLProtocol_MD_VC140_v3_1_LUCID.dll'
)

foreach ($name in $runtimeFiles) {
    $sourcePath = Join-Path $ArenaRuntimeDir $name
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required Arena runtime file was not found: $sourcePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination $projectDir -Force
}

Write-Host 'Build completed.' -ForegroundColor Green
Write-Host "Output: $bridgeOutput"
Write-Host "Output: $readerOutput"
