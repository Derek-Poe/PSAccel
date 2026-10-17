# A small demonstration; not a performance benchmark.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSAccel.psd1') -DisableNameChecking
$rows = @(1..1024 | ForEach-Object { [pscustomobject]@{ Id = $_; Score = $_ % 100 } })
$rows | PSA_Where-Object { $_.Score -ge 95 } | Select-Object -First 10
