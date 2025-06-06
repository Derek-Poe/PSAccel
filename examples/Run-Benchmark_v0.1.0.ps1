function Measure-PsaFilterPerformance {
    [CmdletBinding()]
    param (
        [int]$MaxRecords,
        [switch]$ReturnResults
    )

    if(!($MaxRecords > 0)){ $MaxRecords = 1000000 }
    $returnSize = 0.05
    $dataPointCount = 20
    $pointConcentrationBias_points = 0.5
    $pointConcentrationBias_split = 0.1
    $side1_pointCount = [Math]::Round($dataPointCount * $pointConcentrationBias_points)
    $side2_pointCount = [Math]::Round($dataPointCount - ($dataPointCount * $pointConcentrationBias_points))
    $setSizes = 1..$side1_pointCount | % { [Math]::Round($MaxRecords * $pointConcentrationBias_split / $side1_pointCount * $_) }
    $setSizes += 1..$side2_pointCount | % { [Math]::Round(($MaxRecords * $pointConcentrationBias_split) + ($MaxRecords - ($MaxRecords * $pointConcentrationBias_split)) / $side2_pointCount * $_) }

    Write-Host "n=== System Info ==="

    # CPU Info
    $cpuInfo = Get-CimInstance Win32_Processor | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors
    $cpuInfo| Format-Table

    # GPU Info
    $gpuInfo = Get-CimInstance Win32_VideoController | Select-Object Name, @{n='AdapterRAM(GB)';e={[math]::round($_.AdapterRAM / 1GB, 2)}}, DriverVersion
    $gpuInfo | Format-Table

    # Memory Info
    $totalMemory = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $memoryModules = Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, Capacity, Speed
    $totalMemoryGB = [math]::round($totalMemory / 1GB, 2)

    Write-Host "nTotal Physical Memory: ${totalMemoryGB} GB"
    $memoryModules | ForEach-Object {
        Write-Host ("Module: {0}, Size: {1} GB, Speed: {2} MHz" -f 
            $_.Manufacturer, 
            [math]::round($_.Capacity / 1GB, 2), 
            $_.Speed)
    }

    $results = [System.Collections.Generic.List[psobject]]::new()

    $c = 1
    foreach ($setSize in $SetSizes) {
        Write-Host "n=== Dataset Size: $setSize (Run $c/$($setSizes.Count)) ==="
        $returnThreshold = $setSize - [math]::Round($setSize * $returnSize)

        # Build Data
        $st = Get-Date
        Write-Host "Building Test Data :: $(New-TimeSpan $st (Get-Date))"
        $data = 1..$setSize | ForEach-Object { [pscustomobject]@{ Value = $_ } }
        Write-Host "Done Building Test Data :: $(New-TimeSpan $st (Get-Date))"

        # Native Filter
        $nativeStart = Get-Date
        Write-Host "Running Native Filter :: $(New-TimeSpan $nativeStart (Get-Date))"
        $nativeFiltered = $data | Where-Object { $_.Value -gt $returnThreshold }
        $nativeTime = (New-TimeSpan $nativeStart (Get-Date))
        $nativeCount = $nativeFiltered.Count
        Write-Host "Native Filter Complete :: $nativeTime"
        Write-Host "Native Return Count :: $nativeCount"

        $nativeFiltered = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        # PSA Filter
        $psaStart = Get-Date
        Write-Host "Running PSA Filter :: $(New-TimeSpan $psaStart (Get-Date))"
        $psaFiltered = $data | ?G { $_.Value -gt $returnThreshold }
        $psaTime = (New-TimeSpan $psaStart (Get-Date))
        $psaCount = $psaFiltered.Count
        Write-Host "PSA Filter Complete :: $psaTime"
        Write-Host "PSA Return Count :: $psaCount"

        $nativeMs = [math]::Round($nativeTime.TotalMilliseconds, 2)
        $psaMs = [math]::Round($psaTime.TotalMilliseconds, 2)

        $speedup = if ($psaMs -ne 0) { [math]::Round($nativeMs / $psaMs, 2) } else { '∞' }

        Write-Host ("Speedup (Native / PSA): {0}x faster" -f $speedup)

        $psaFiltered = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        if ($ReturnResults) {
            $results.Add([pscustomobject]@{
                SetSize          = $setSize
                ReturnThreshold  = $returnThreshold
                NativeTime       = $nativeTime.TotalMilliseconds
                NativeCount      = $nativeCount
                PsaTime          = $psaTime.TotalMilliseconds
                PsaCount         = $psaCount
                Speedup          = if ($psaTime.TotalMilliseconds -gt 0) { $nativeTime.TotalMilliseconds / $psaTime.TotalMilliseconds } else { [double]::NaN }
                CPU              = $cpuInfo.Name
                GPU              = $gpuInfo.Name
                Memory           = "$totalMemoryGBGB"
            })
        }
        $c++
    }

    if ($ReturnResults) {
        $csvPath = "psa_benchmark_results.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Force
        Write-Host "nBenchmark results saved to: $csvPath"
        Start-Process python "GraphBenchmarkResults.py"
        return $results
    }
}

Measure-PsaFilterPerformance