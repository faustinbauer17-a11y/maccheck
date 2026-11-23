# Builds and runs MacCheck's platform-independent unit tests on Windows.
# Uses `swift test` when available; otherwise falls back to swift-build + running the test binary
# directly (needed if swift.exe/swift-test.exe are missing from the toolchain).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$toolchain = Get-ChildItem (Join-Path $swiftRoot 'Toolchains') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$platform  = Get-ChildItem (Join-Path $swiftRoot 'Platforms') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$bin = Join-Path $toolchain.FullName 'usr\bin'
$ver = $platform.Name
$xctest  = Join-Path $platform.FullName "Windows.platform\Developer\Library\XCTest-$ver\usr\bin64"
$testing = Join-Path $platform.FullName "Windows.platform\Developer\Library\Testing-$ver\usr\bin64"
$runtime = Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$env:Path = "$bin;$xctest;$testing;$(Join-Path $runtime.FullName 'usr\bin');$env:Path"

if (Test-Path (Join-Path $bin 'swift-test.exe')) {
    swift-test.exe @args
    exit $LASTEXITCODE
}

Write-Host "swift-test.exe not found; building with swift-build and running the test binary directly."
& (Join-Path $bin 'swift-build.exe') --build-tests
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$runner = Get-ChildItem .build -Recurse -Filter 'MacCheckCoreTests-test-runner.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $runner) { Write-Error 'Test runner not found.'; exit 1 }
Push-Location $runner.DirectoryName
& $runner.FullName @args
$code = $LASTEXITCODE
Pop-Location
exit $code
