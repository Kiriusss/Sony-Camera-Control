param([string]$SdkPath = "", [switch]$SkipDependencies)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$python = Join-Path $root "build/venv-win/Scripts/python.exe"
if (!(Test-Path $python)) {
    py -3.12 -m venv (Join-Path $root "build/venv-win")
    if ($LASTEXITCODE) { throw "Python 3.12 is required (py -3.12)." }
}
if (!$SkipDependencies) {
    & $python -m pip install -r requirements-desktop.txt cmake==3.31.10 ninja==1.13.0
    if ($LASTEXITCODE) { throw "Dependency installation failed" }
}
$buildArgs = @("Scripts/build-desktop.py")
if ($SdkPath) { $buildArgs += @("--sdk", $SdkPath) }
& $python @buildArgs
if ($LASTEXITCODE) { throw "Windows build failed" }
