# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('rad12-win32', 'rad13-win32', 'rad13-win64')]
    [string]$Target,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{40}$')]
    [string]$Commit
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $Target.EndsWith($Platform.ToLowerInvariant())) {
    throw 'Target and platform do not match.'
}
$root = Split-Path -Parent $PSScriptRoot
$binary = Join-Path $root "build/$Platform/EverywhereRAD.bpl"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or (Get-Item -LiteralPath $binary).Length -eq 0) {
    throw 'Nonempty EverywhereRAD.bpl required; run a successful native build first.'
}
$evidencePath = Join-Path $root "build/$Platform/build-evidence.json"
$evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
if ($evidence.platform -ne $Platform -or $evidence.nativeBuildExecuted -ne $true -or
    $evidence.protocolTestsPassed -ne $true -or [string]::IsNullOrWhiteSpace($evidence.compilerFileVersion)) {
    throw 'Successful native build and protocol tests with compiler version evidence required.'
}
$output = Join-Path $root 'build/artifacts'
$stage = Join-Path $root 'build/package-stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $output, $stage | Out-Null
# Explicit allowlist: never include SDK DLLs, DCP/DCU, credentials or compiler logs.
Copy-Item -LiteralPath $binary -Destination $stage
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $root) 'LICENSE') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $stage
New-Item -ItemType Directory -Path (Join-Path $stage 'docs') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'docs/COMPATIBILITY.md') -Destination (Join-Path $stage 'docs')
Copy-Item -LiteralPath (Join-Path $root 'compatibility.json') -Destination $stage
$manifest = [ordered]@{
    schemaVersion = 1
    target = $Target
    platform = $Platform
    commit = $Commit.ToLowerInvariant()
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    compiler = $evidence.compiler
    compilerFileVersion = $evidence.compilerFileVersion
    protocolTestsPassed = $true
    package = 'EverywhereRAD.bpl'
    sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    ideSmokeTest = 'pending'
    status = 'experimental'
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'build-manifest.json') -Encoding UTF8
$instructions = @(
    'EXPERIMENTAL - RAD Studio package for IDE testing',
    '',
    '1. Read build-manifest.json. Use ONLY the compiler/IDE version provisioned',
    '   for the target runner and its matching IDE architecture.',
    '   Runner labels are operator-configured, not proof of ABI compatibility.',
    '2. Install official WebView2 Runtime and matching WebView2Loader separately.',
    '3. Extract to a permanent folder, never the IDE bin directory.',
    '4. RAD Studio: Component > Install Packages > Add > EverywhereRAD.bpl.',
    '5. Open a saved Delphi/C++Builder project and use EveryWhere Harness.',
    '6. Complete docs/COMPATIBILITY.md before approving distribution.',
    '',
    'Build does not certify IDE compatibility. Do not install this BPL on RAD 10.',
    'README is source documentation; source-only links require the repository.'
)
$instructions | Set-Content -LiteralPath (Join-Path $stage 'INSTALL.txt') -Encoding UTF8
$zip = Join-Path $output "everywhere-embarcadero-$Target-$($Commit.Substring(0, 12)).zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Write-Host "Created $zip"
