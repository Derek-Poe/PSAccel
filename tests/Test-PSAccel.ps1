param([switch]$Gpu)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $root 'PSAccel.psd1'
$script:checks = 0
function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function Assert-Rejected([scriptblock]$action, [string]$message) {
    $rejected = $false
    try { & $action | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}

Push-Location ([IO.Path]::GetTempPath())
try { Import-Module $manifest -Force -DisableNameChecking } finally { Pop-Location }
$metadata = Test-ModuleManifest $manifest
foreach ($file in $metadata.FileList) { Assert (Test-Path -LiteralPath $file) "Missing manifest file: $file" }
Import-Module $manifest -Force -DisableNameChecking
Assert ($null -ne (Get-Command PSA_Where-Object)) 'Import/reimport from another directory failed.'
Assert (@(PSA_Where-Object { $_.Value -gt 0 } -InputData @()).Count -eq 0) 'Empty input returned rows.'
foreach ($invalid in @(
    { $_.Value -like '*' }, { $_.Value -eq 'abc' }, { $_.Value.ToString() -eq '1' },
    { $_.Value -gt 1; $_.Value -lt 4 }, { Get-Process }, { $_ -gt 1 },
    { $_.Value -gt (Get-Random) }, { param($value) $_.Value -gt $value },
    { ($_.Value -eq 1) -eq 2 }, { -($_.Value -eq 1) -lt 0 },
    { $_.Value -and $_.Score }
)) {
    Assert-Rejected { PSA_Where-Object $invalid -InputData @() } 'Unsupported syntax was accepted.'
}

if ($Gpu) {
    # Non-multiple of the 256-thread group size exercises the tail bound.
    $rows = @(1..513 | ForEach-Object {
        [pscustomobject]@{ Id = $_; Value = $_; Score = $_ % 7; Offset = $_ % 11 }
    })
    $predicates = @(
        { $_.Value -gt 410 }, { $_.Value -lt 100 }, { $_.Value -ge 410 },
        { $_.Value -le 100 }, { $_.Value -eq 100 }, { $_.Value -ne 100 },
        { $_.Value -gt 12 -and $_.Score -eq 2 },
        { $_.Offset -le 2 -or $_.Score -gt 5 -or $_.Value -le 15 },
        { ($_.Value -gt 12 -and $_.Score -eq 2) -or $_.Offset -eq 10 },
        { $_.Value -gt 410 -or $_.Score -eq 2 -and $_.Offset -eq 10 },
        { $_.Value -gt 12 -and $_.value -lt 15 },
        { $_.Value -gt 1000 }, { $_.Value -gt -1 }
    )
    foreach ($predicate in $predicates) {
        $expected = @($rows | Where-Object $predicate)
        $actual = @($rows | PSA_Where-Object $predicate)
        Assert (($actual.Id -join ',') -eq ($expected.Id -join ',')) "Exact-output mismatch: $predicate"
        for ($i = 0; $i -lt $actual.Count; $i++) {
            Assert ([object]::ReferenceEquals($actual[$i], $expected[$i])) 'Output identity/order changed.'
        }
    }
    $one = @(PSA_Where-Object { $_.Value -gt 0 } -InputData @($rows[0]))
    Assert ($one.Count -eq 1 -and $one[0].Id -eq 1) 'Single-row InputData failed.'
    $threshold = 12
    $threshold2 = 15
    $variableResult = @($rows | PSA_Where-Object { $_.Value -gt $threshold -and $_.Value -lt $threshold2 })
    Assert (($variableResult.Id -join ',') -eq '13,14') 'Variable binding or overlapping variable names failed.'
    $threshold = 2
    $closure = { $_.Value -gt $threshold }.GetNewClosure()
    $threshold = 5
    $closedExpected = @($rows | Where-Object $closure)
    $closedActual = @($rows | PSA_Where-Object $closure)
    Assert (($closedExpected.Id -join ',') -eq ($closedActual.Id -join ',')) 'Captured variable binding changed.'
    $reservedNames = @([pscustomobject]@{ i=1; data=2; output=3; float=4 })
    $reservedResult = @(PSA_Where-Object { $_.i -lt $_.data -and $_.output -lt $_.float } -InputData $reservedNames)
    Assert ($reservedResult.Count -eq 1) 'Property names collided with generated HLSL identifiers.'
    $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]'fr-FR'
        $threshold = 12.5
        $cultureResult = @($rows | PSA_Where-Object { $_.Value -gt $threshold -and $_.Value -lt 15 })
        Assert (($cultureResult.Id -join ',') -eq '13,14') 'Locale changed numeric shader generation.'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
    foreach ($invalidRow in @(
        [pscustomobject]@{ Other = 1 }, [pscustomobject]@{ Value = $null },
        [pscustomobject]@{ Value = '12' }, [pscustomobject]@{ Value = [double]::NaN },
        [pscustomobject]@{ Value = [double]::PositiveInfinity }
    )) {
        Assert-Rejected { PSA_Where-Object { $_.Value -gt 0 } -InputData @($invalidRow) } 'Invalid input silently converted.'
    }
    Assert-Rejected { [PSAccel]::RunStructuredFilter([single[]]@(1), 1, 'invalid shader') } 'Invalid shader did not fail.'
    # A compile failure must leave the device usable on the next invocation.
    Assert (@($rows | PSA_Where-Object { $_.Value -eq 42 }).Count -eq 1) 'Recovery after shader failure failed.'
}
Write-Output "PASS: $script:checks assertions; GPU checks requested: $Gpu"
