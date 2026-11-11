# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Bds,

    [ValidateSet('Win32', 'Win64')]
    [string]$Platform = 'Win32',

    [switch]$RunTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate before creating outputs: headers or a C++-only install are insufficient.
if (-not (Test-Path -LiteralPath $Bds -PathType Container)) {
    throw "BDS root not found: $Bds"
}
$Bds = (Resolve-Path -LiteralPath $Bds).Path
$Platform = if ($Platform -ieq 'Win64') { 'Win64' } else { 'Win32' }
$compilerName = if ($Platform -eq 'Win64') { 'dcc64.exe' } else { 'dcc32.exe' }
$compiler = Join-Path $Bds "bin/$compilerName"
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "Delphi compiler not found: $compiler. Install a licensed Delphi toolchain; C++ headers are not a compiler."
}
$library = Join-Path $Bds "lib/$Platform/release"
if (-not (Test-Path -LiteralPath $library -PathType Container)) {
    throw "Delphi platform libraries not found: $library"
}
if (-not (Test-Path -LiteralPath (Join-Path $library 'designide.dcp') -PathType Leaf)) {
    throw "OTA designide.dcp not found for $Platform in $library. Check licensed IDE platform support."
}

$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root "build/$Platform"
$units = Join-Path $output 'dcu'
# Never accept an old BPL/test result from another compiler or prior build.
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
New-Item -ItemType Directory -Force -Path $output, $units | Out-Null
$source = Join-Path $root 'src'
# -B: rebuild; -Q: quiet banner; -E/-LE/-LN/-N0: keep all generated files out of sources.
$common = @('-B', '-Q', "-U$source;$library", "-I$source", "-R$library", "-N0$units", "-E$output")
Push-Location $root
try {
    & $compiler @common "-LE$output" "-LN$output" (Join-Path $root 'EverywhereRAD.dpk')
    if ($LASTEXITCODE -ne 0) {
        throw "Delphi package compilation failed (exit $LASTEXITCODE)."
    }
    $package = Join-Path $output 'EverywhereRAD.bpl'
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        throw "Compiler did not produce the expected package: $package"
    }
    if ($RunTests) {
        & $compiler @common (Join-Path $root 'tests/ProtocolTests.dpr')
        if ($LASTEXITCODE -ne 0) {
            throw "Protocol test compilation failed (exit $LASTEXITCODE)."
        }
        $testExe = Join-Path $output 'ProtocolTests.exe'
        if (-not (Test-Path -LiteralPath $testExe -PathType Leaf)) {
            throw "Compiler did not produce protocol tests: $testExe"
        }
        & $testExe
        if ($LASTEXITCODE -ne 0) {
            throw "Protocol tests failed (exit $LASTEXITCODE)."
        }
    }
    $evidence = [ordered]@{
        platform = $Platform
        compiler = $compilerName
        compilerFileVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        nativeBuildExecuted = $true
        protocolTestsPassed = [bool]$RunTests
        ideSmokeTest = 'pending'
    }
    $evidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'build-evidence.json') -Encoding UTF8
    Write-Host "Built $package. Install manually in the matching IDE architecture."
}
finally {
    Pop-Location
}
