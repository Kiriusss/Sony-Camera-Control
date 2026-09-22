#Requires -RunAsAdministrator
param([string]$DriverDirectory = "")
$ErrorActionPreference = "Stop"
if (!$DriverDirectory) { $DriverDirectory = Join-Path $PSScriptRoot "drivers" }
$inf = Join-Path $DriverDirectory "srcameradriver.inf"
$catalog = Join-Path $DriverDirectory "srcameradriver.cat"
if (!(Test-Path -LiteralPath $inf)) { throw "Sony SDK driver missing: $inf" }
if ((Get-AuthenticodeSignature -LiteralPath $catalog).Status -ne 'Valid') { throw "Sony driver catalog signature is not valid." }
& pnputil.exe /add-driver $inf /install
if ($LASTEXITCODE -notin @(0, 3010)) { throw "Sony driver installation failed: $LASTEXITCODE" }
Write-Output "Sony driver installed. If the camera is not found, reconnect its USB cable in PC Remote mode."
