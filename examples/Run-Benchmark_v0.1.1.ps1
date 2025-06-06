Import-Module .\PSAccel.psm1

function Get-RandomFilterExpression {
    param (
        [PSCustomObject]$MaxRecord
    )

    $props = @('Value', 'Score', 'Offset')
    $ops = @(' -gt ', ' -lt ', ' -ge ', ' -le ', ' -eq ', ' -ne ')
    $logic = @(' -and ', ' -or ')

    function Get-SimpleClause {
        $prop = $props | Get-Random
        $maxThreshold = [math]::Floor($MaxRecord.$prop * 0.95)
        $prop = "`$_.$prop"
        $op = $ops | Get-Random
        $val = [Math]::Round((Get-Random -Minimum 1 -Maximum $maxThreshold))
        return "$prop$op$val"
    }

    function Get-NestedExpression {
        $depth = Get-Random -Minimum 1 -Maximum 2
        $clauses = @()

        for ($i = 0; $i -lt (Get-Random -Minimum 2 -Maximum 4); $i++) {
            if ($depth -gt 1 -and (Get-Random -Minimum 0 -Maximum 1)) {
                $subExpr = Get-NestedExpression
                $clauses += "($subExpr)"
            } else {
                $clauses += Get-SimpleClause
            }
        }

        return ($clauses -join ($logic | Get-Random))
    }

    return Get-NestedExpression
}

function Measure-PsaFilterPerformance {
    [CmdletBinding()]
    param (
        [int]$MaxRecords = 1000000,
        [switch]$ReturnResults
    )

    $returnSize = 0.05
    $dataPointCount = 20
    $pointConcentrationBias_points = 0.5
    $pointConcentrationBias_split = 0.1

    $side1_pointCount = [Math]::Round($dataPointCount * $pointConcentrationBias_points)
    $side2_pointCount = [Math]::Round($dataPointCount - $side1_pointCount)

    $setSizes = 1..$side1_pointCount | % { [Math]::Round($MaxRecords * $pointConcentrationBias_split / $side1_pointCount * $_) }
    $setSizes += 1..$side2_pointCount | % { [Math]::Round(($MaxRecords * $pointConcentrationBias_split) + ($MaxRecords - ($MaxRecords * $pointConcentrationBias_split)) / $side2_pointCount * $_) }

    Write-Host "`n=== System Info ==="
    Get-CimInstance Win32_Processor | Format-Table Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors
    Get-CimInstance Win32_VideoController | Format-Table Name, @{n='AdapterRAM(GB)';e={[math]::round($_.AdapterRAM / 1GB, 2)}}, DriverVersion

    $totalMemory = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $totalMemoryGB = [math]::round($totalMemory / 1GB, 2)
    Write-Host "`nTotal Physical Memory: ${totalMemoryGB} GB"

    $results = [System.Collections.Generic.List[psobject]]::new()

    # Build full data once
    Write-Host "`n=== Building Full Dataset (Size: $MaxRecords) ==="
    $fullData = 1..$MaxRecords | ForEach-Object {
        [pscustomobject]@{
            Value  = $_
            Score  = ($_ * 1.5) % 100
            Offset = ($_ + 10) % 50
        }
    }

    $cpuInfo = (Get-CimInstance Win32_Processor)[0].Name
    $dxdiagFile = "dxdiag_benchmark.xml"
    Start-Process "dxdiag.exe" "/x $dxdiagFile" -Wait -WindowStyle Hidden
    [xml]$dxdiag = Get-Content $dxdiagFile

    $gpuInfo = $dxdiag.DxDiag.DisplayDevices.DisplayDevice |
        Where-Object { $_.ChipType -and $_.DedicatedMemory -gt 0 } |
        Sort-Object { $_.DedicatedMemory } -Descending |
        Select-Object -First 1

    $gpuName = $gpuInfo.Description
    $gpuVRAM = $gpuInfo.DedicatedMemory

    $c = 1
    foreach ($setSize in $setSizes) {
        if ($setSize -gt $fullData.Count) { continue }

        Write-Host "`n=== Dataset Size: $setSize (Run $c/$($setSizes.Count)) ==="
        $data = $fullData[0..($setSize - 1)]

        $filterExpression = Get-RandomFilterExpression ([PSCustomObject]@{
            Value = ($data.Value | Measure -Maximum).Maximum
            Score = ($data.Score | Measure -Maximum).Maximum
            Offset = ($data.Offset | Measure -Maximum).Maximum
        })

        # Native Filter
        $nativeStart = Get-Date
        Invoke-Expression "`$nativeFiltered = `$data | Where-Object {$filterExpression}"
        $nativeTime = (New-TimeSpan $nativeStart (Get-Date))
        $nativeCount = $nativeFiltered.Count
        Write-Host "Native: $nativeCount in $([math]::Round($nativeTime.TotalMilliseconds, 2)) ms"

        $nativeFiltered = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()

        # PSA Filter
        $psaStart = Get-Date
        Invoke-Expression "`$psaFiltered = `$data | PSA_Where-Object {$filterExpression}"
        $psaTime = (New-TimeSpan $psaStart (Get-Date))
        $psaCount = $psaFiltered.Count
        Write-Host "PSAccel: $psaCount in $([math]::Round($psaTime.TotalMilliseconds, 2)) ms"

        $speedup = if ($psaTime.TotalMilliseconds -gt 0) {
            [math]::Round($nativeTime.TotalMilliseconds / $psaTime.TotalMilliseconds, 2)
        } else { '∞' }
        Write-Host "Speedup: ${speedup}x"

        $psaFiltered = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()

        if ($ReturnResults) {
            $results.Add([pscustomobject]@{
                SetSize         = $setSize
                Expression      = $filterExpression.ToString()
                NativeTime      = $nativeTime.TotalMilliseconds
                NativeCount     = $nativeCount
                PsaTime         = $psaTime.TotalMilliseconds
                PsaCount        = $psaCount
                Speedup         = $speedup
                CPU             = $cpuInfo
                GPU             = $gpuName
                GPU_VRAM        = $gpuVRAM
                Memory          = "$totalMemoryGB GB"
                TestType        = "Multi-Prop Nested Filter"
            })
        }

        $c++
    }

    if ($ReturnResults) {
        $csvPath = "psa_benchmark_results.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Force
        Write-Host "`nBenchmark results saved to: $csvPath"
        return $results
    }
}

# Run it
Measure-PsaFilterPerformance -ReturnResults