<#
Reproducible warm end-to-end comparison of PSAccel 0.2.0 with PowerShell and C#.
Run in a fresh 64-bit Windows PowerShell 5.1 process; see README.md for scope.
#>
[CmdletBinding()]
param(
    [ValidateScript({$_ -ge 1000 -and $_ -le 500000})]
    [int[]]$Sizes = @(10000, 100000, 500000),
    [ValidateRange(1, 10)][int]$WarmupRuns = 2,
    [ValidateRange(4, 40)][int]$Repetitions = 8,
    [int]$OrderSeed = 20261018,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot ('results/run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Use a fresh 64-bit Windows PowerShell 5.1 process.'
}
if ('PSAccel' -as [type]) { throw 'PSAccel is already loaded. Start a fresh PowerShell process so recorded source matches the loaded type.' }
if ($env:PSACCEL_D3D_DEBUG -eq '1') { throw 'Disable the optional D3D debug layer for this timing run.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath (Join-Path $output 'observations.csv')) { throw 'Output already contains observations; choose a new directory.' }
New-Item -ItemType Directory -Force -Path $output | Out-Null
$moduleRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $moduleRoot 'PSAccel.psd1') -Force -DisableNameChecking
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CpuBaseline.cs'))) -Language CSharp
$sourceFiles = @('PSAccel.psm1','PSAccel.cs','PSAccel.psd1','benchmark/current/Run-CurrentBenchmark.ps1','benchmark/current/CpuBaseline.cs')
$sources = @($sourceFiles | ForEach-Object {
    $file=Join-Path $moduleRoot $_
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $canonical=[Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($file).Replace("`r`n","`n"))
        $normalized=([BitConverter]::ToString($sha.ComputeHash($canonical))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
    [pscustomobject]@{path=$_;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant();sha256_utf8_lf_without_bom=$normalized}
})
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
$environment = [ordered]@{
    schema_version=1;host_label='integrated_gpu_host_01';started_utc=[DateTime]::UtcNow.ToString('o');
    module_version=(Get-Module PSAccel).Version.ToString();powershell_version=$PSVersionTable.PSVersion.ToString();
    clr_version=$PSVersionTable.CLRVersion.ToString();os_caption=$os.Caption;os_version=$os.Version;
    cpu=$cpu.Name;physical_cores=$cpu.NumberOfCores;logical_processors=$cpu.NumberOfLogicalProcessors;
    gpus=$gpu;total_memory_gib=[Math]::Round($os.TotalVisibleMemorySize / 1MB, 2);
    available_memory_gib_at_start=[Math]::Round($os.FreePhysicalMemory / 1MB, 2);
    sizes=$Sizes;warmup_runs=$WarmupRuns;measured_repetitions=$Repetitions;order_seed=$OrderSeed;
    timing='Stopwatch around complete filter invocation and result-array materialization; excludes generation, compilation/import, warmup, verification and hashing';
    correctness='Native Where-Object reference; every warmup and measured result checked for exact count, order and BaseObject reference identity; SHA256 of UTF-8 Id lines';
    cpu_baseline='Specialized single-thread C# loop reads integer PSObject properties directly with Boolean short-circuiting. No preprojection. Assumes fixed valid synthetic schema; not a general Where-Object replacement.';
    runtime_state='Existing interactive Windows host; foreground/background services and power management not controlled; natural GC retained during timings';
    source_files=$sources
}
$environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
$methods = @('WhereObject','PSAccelPipeline','PSAccelInputData','CSharpLoop')
$rng = [Random]::new($OrderSeed)
$observations = [Collections.Generic.List[object]]::new()
$caseIndex = 0

foreach ($size in $Sizes) {
    Write-Host ('Generating {0:N0} deterministic PSCustomObject rows...' -f $size)
    $inputRows = [Management.Automation.PSObject[]]::new($size)
    for ($i=0; $i -lt $size; $i++) {
        $inputRows[$i] = [pscustomobject]@{Id=$i;Value=([int](($i*37)%1000));Group=([int](($i*13)%17));Offset=([int](($i*19)%23))}
    }
    foreach ($scenario in @('SingleProperty','ThreeProperty')) {
        $caseIndex++
        $predicate = if ($scenario -eq 'SingleProperty') { { $_.Value -ge 900 } } else { { ($_.Value -ge 500 -and $_.Group -lt 4) -or $_.Offset -eq 0 } }
        [Management.Automation.PSObject[]]$expected = @($inputRows | Where-Object $predicate)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        # A seeded permutation, rotated each round, balances the four methods' positions.
        $permutation = @($methods)
        for ($j=$permutation.Length-1; $j -gt 0; $j--) {
            $k=$rng.Next($j+1);$swap=$permutation[$j];$permutation[$j]=$permutation[$k];$permutation[$k]=$swap
        }
        foreach ($phase in @('warmup','measured')) {
            $rounds = if ($phase -eq 'warmup') {$WarmupRuns} else {$Repetitions}
            for ($repeat=1; $repeat -le $rounds; $repeat++) {
                for ($position=0; $position -lt $methods.Length; $position++) {
                    $method=$permutation[($position+$repeat-1)%$methods.Length]
                    $gcBefore=@([GC]::CollectionCount(0),[GC]::CollectionCount(1),[GC]::CollectionCount(2))
                    [Management.Automation.PSObject[]]$actual = $null
                    $timer=[Diagnostics.Stopwatch]::StartNew()
                    switch ($method) {
                        'WhereObject' { $actual=@($inputRows | Where-Object $predicate); break }
                        'PSAccelPipeline' { $actual=@($inputRows | PSA_Where-Object $predicate); break }
                        'PSAccelInputData' { $actual=@(PSA_Where-Object $predicate -InputData $inputRows); break }
                        'CSharpLoop' { $actual=[PSAccelCurrentBenchmark]::Filter($inputRows,$scenario); break }
                    }
                    $timer.Stop()
                    $gcAfter=@([GC]::CollectionCount(0),[GC]::CollectionCount(1),[GC]::CollectionCount(2))
                    $checksum=[PSAccelCurrentBenchmark]::VerifyAndHash($expected,$actual)
                    $observations.Add([pscustomobject][ordered]@{
                        host_label='integrated_gpu_host_01';module_version='0.2.0';case_index=$caseIndex;
                        scenario=$scenario;rows=$size;phase=$phase;repeat=$repeat;order_position=($position+1);method=$method;
                        elapsed_ms=[Math]::Round($timer.Elapsed.TotalMilliseconds,6);result_count=$actual.Length;
                        exact_identity_and_order=$true;result_id_sha256=$checksum;
                        gc0=($gcAfter[0]-$gcBefore[0]);gc1=($gcAfter[1]-$gcBefore[1]);gc2=($gcAfter[2]-$gcBefore[2])
                    })
                    $actual=$null
                }
                Write-Host ('{0} {1:N0}: {2} round {3}/{4} verified' -f $scenario,$size,$phase,$repeat,$rounds)
                $observations | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $output 'observations.csv')
            }
        }
        $expected=$null
    }
    $inputRows=$null
}
$environment['completed_utc']=[DateTime]::UtcNow.ToString('o')
$environment['observations']= $observations.Count
$environment['measured_observations']=@($observations | Where-Object phase -eq 'measured').Count
$environment['observations_sha256']=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output 'observations.csv')).Hash.ToLowerInvariant()
$environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
Write-Host ('Completed: {0} verified observations saved under {1}' -f $observations.Count,$output)
