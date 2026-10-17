#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet("ValidateOnly", "SmokeTest", "FinalOfficial", "AnalyzeOnly", "ArchiveOnly", "SummarizeOnly")]
    [string]$Mode = "ValidateOnly",
    [string]$ConfigPath,
    [string]$RunRoot,
    [switch]$AllowDirtyRepo
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonCandidates = @(
    (Join-Path $scriptRoot "..\psaccel-final-framework-capture\lib\PSAccelFinal.Common.ps1"),
    (Join-Path $scriptRoot "lib\PSAccelFinal.Common.ps1")
)
$commonPath = $commonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $commonPath) { throw "Unable to locate PSAccelFinal.Common.ps1." }
. $commonPath

class FRSyntheticRecord {
    [int]$Value
    [double]$Score
    [int]$Offset

    FRSyntheticRecord([int]$value) {
        $this.Value = $value
        $this.Score = ($value * 1.5) % 100
        $this.Offset = ($value + 10) % 50
    }
}

function Resolve-FRConfigPath {
    param([string]$Path)
    if ($Path) { return (Resolve-Path -LiteralPath $Path).Path }
    $concrete = Join-Path $scriptRoot "framework-replacement-config.json"
    if (Test-Path -LiteralPath $concrete) { return (Resolve-Path -LiteralPath $concrete).Path }
    return (Resolve-Path -LiteralPath (Join-Path $scriptRoot "framework-replacement-config.example.json")).Path
}

function Read-FRConfig {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Resolve-FRPredicate {
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][int]$DatasetSize
    )
    $resolved = $Template
    $resolved = $resolved.Replace("{Threshold95}", [string][math]::Floor($DatasetSize * 0.95))
    $resolved = $resolved.Replace("{Threshold58}", [string][math]::Floor($DatasetSize * 0.58))
    $resolved = $resolved.Replace("{Threshold15}", [string][math]::Floor($DatasetSize * 0.15))
    return $resolved
}

function New-FRRunRoot {
    param([Parameter(Mandatory)]$Config)
    $stamp = Get-Date -Format "yyyyMMddTHHmmss"
    $base = Join-Path ([string]$Config.OutputRoot) ([string]$Config.RunFamily)
    New-FCDirectory -Path $base
    $path = Join-Path $base ("{0}-{1}" -f $Config.RunFamily, $stamp)
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite existing run folder: $path" }
    New-FCDirectory -Path $path
    return $path
}

function Get-FRDefaultDatasetMode {
    param([Parameter(Mandatory)]$Config)
    if ($Config.PSObject.Properties.Name -contains "WorkloadGroups") {
        $firstGroup = @($Config.WorkloadGroups) | Select-Object -First 1
        if ($firstGroup -and ($firstGroup.PSObject.Properties.Name -contains "DatasetMode")) {
            return [string]$firstGroup.DatasetMode
        }
    }
    if ($Config.PSObject.Properties.Name -contains "DatasetShape") { return [string]$Config.DatasetShape }
    return "RepositoryStylePSCustomObject_ValueScoreOffset"
}

function New-FRDataset {
    param(
        [Parameter(Mandatory)][int]$DatasetSize,
        [Parameter(Mandatory)][string]$DatasetMode
    )
    $list = New-Object "System.Collections.Generic.List[object]"
    for ($i = 1; $i -le $DatasetSize; $i++) {
        if ($DatasetMode -eq "RepositoryStyleSyntheticRecordClass_ValueScoreOffset") {
            $list.Add([FRSyntheticRecord]::new($i))
        }
        else {
            $list.Add([pscustomobject]@{
                Value = $i
                Score = ($i * 1.5) % 100
                Offset = ($i + 10) % 50
            })
        }
    }
    return $list.ToArray()
}

function Resolve-FRMatrix {
    param([Parameter(Mandatory)]$Config)
    $matrix = New-Object System.Collections.Generic.List[object]

    $groups = @()
    if ($Config.PSObject.Properties.Name -contains "WorkloadGroups") {
        $groups = @($Config.WorkloadGroups)
    }
    else {
        $groups = @([pscustomobject]@{
            WorkloadGroup = "FrameworkReplacementWorkloads"
            DatasetMode = [string]$Config.DatasetShape
            DatasetSizes = @($Config.DatasetSizes)
            Scenarios = @($Config.Scenarios)
        })
    }

    foreach ($group in $groups) {
        $datasetMode = [string]$group.DatasetMode
        $workloadGroup = [string]$group.WorkloadGroup
        foreach ($size in @($group.DatasetSizes)) {
            foreach ($scenario in @($group.Scenarios)) {
                $expr = Resolve-FRPredicate -Template ([string]$scenario.PredicateTemplate) -DatasetSize ([int]$size)
                $matrix.Add([pscustomobject]@{
                    WorkloadGroup = $workloadGroup
                    ScenarioName = [string]$scenario.ScenarioName
                    DatasetMode = $datasetMode
                    DatasetSize = [int]$size
                    Distribution = "Value=1..N; Score=(Value*1.5)%100; Offset=(Value+10)%50"
                    PredicateName = [string]$scenario.PredicateName
                    PredicateExpression = $expr
                    PredicateTemplate = [string]$scenario.PredicateTemplate
                    SelectivityLabel = [string]$scenario.SelectivityLabel
                    Rationale = [string]$scenario.Rationale
                    Methodology = "Native Where-Object baseline versus PSA_Where-Object framework replacement."
                    OfficialAnalysisEligible = $true
                    DiagnosticOnly = $false
                })
            }
        }
    }
    return $matrix.ToArray()
}

function Resolve-FRSkippedScenarios {
    param([Parameter(Mandatory)]$Config)
    $skipped = New-Object System.Collections.Generic.List[object]
    if ($Config.PSObject.Properties.Name -notcontains "SkippedWorkloadTiers") {
        return $skipped.ToArray()
    }
    foreach ($item in @($Config.SkippedWorkloadTiers)) {
        $skipped.Add([pscustomobject]@{
            WorkloadGroup = [string]$item.WorkloadGroup
            ScenarioName = [string]$item.ScenarioName
            DatasetMode = [string]$item.DatasetMode
            DatasetSize = [int]$item.DatasetSize
            Reason = [string]$item.Reason
            Predeclared = $true
            ExcludedFromPerformanceAnalysis = $true
        })
    }
    return $skipped.ToArray()
}

function New-FRRunPlan {
    param(
        [Parameter(Mandatory)][object[]]$Matrix,
        [Parameter(Mandatory)][int]$TrialsPerMethod,
        [Parameter(Mandatory)][int]$RandomSeed
    )
    $random = New-Object System.Random($RandomSeed)
    $plan = New-Object System.Collections.Generic.List[object]
    $sequence = 0
    foreach ($scenario in $Matrix) {
        for ($trial = 1; $trial -le $TrialsPerMethod; $trial++) {
            $methods = if ($random.Next(0, 2) -eq 0) {
                @("CPUWhereObject", "PSAccelWhereObject")
            }
            else {
                @("PSAccelWhereObject", "CPUWhereObject")
            }
            foreach ($method in $methods) {
                $sequence++
                $plan.Add([pscustomobject]@{
                    Sequence = $sequence
                    WorkloadGroup = $scenario.WorkloadGroup
                    ScenarioName = $scenario.ScenarioName
                    DatasetMode = $scenario.DatasetMode
                    DatasetSize = $scenario.DatasetSize
                    Distribution = $scenario.Distribution
                    PredicateName = $scenario.PredicateName
                    PredicateExpression = $scenario.PredicateExpression
                    SelectivityLabel = $scenario.SelectivityLabel
                    Trial = $trial
                    Method = $method
                    Warmup = $false
                    OfficialAnalysisEligible = $true
                })
            }
        }
    }
    return $plan.ToArray()
}

function Write-FRMatrixMarkdown {
    param(
        [Parameter(Mandatory)][object[]]$Matrix,
        [Parameter(Mandatory)][string]$Path
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Framework Replacement Official Matrix")
    $lines.Add("")
    $lines.Add("This matrix was resolved and written before official observations began.")
    $lines.Add("")
    $lines.Add("| Workload group | Scenario | Dataset mode | Size | Predicate | Selectivity | Rationale |")
    $lines.Add("|---|---|---|---:|---|---|---|")
    foreach ($row in $Matrix) {
        $lines.Add("| $($row.WorkloadGroup) | $($row.ScenarioName) | $($row.DatasetMode) | $($row.DatasetSize) | `$($row.PredicateExpression)` | $($row.SelectivityLabel) | $($row.Rationale) |")
    }
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-FRSkippedMarkdown {
    param(
        [Parameter(Mandatory)][object[]]$Skipped,
        [Parameter(Mandatory)][string]$Path
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Predeclared Skipped Workload Tiers")
    $lines.Add("")
    $lines.Add("These tiers were declared before the fresh final run began and are excluded from performance analysis.")
    $lines.Add("")
    if ($Skipped.Count -eq 0) {
        $lines.Add("No workload tiers were skipped.")
    }
    else {
        $lines.Add("| Workload group | Scenario | Dataset mode | Size | Reason |")
        $lines.Add("|---|---|---|---:|---|")
        foreach ($row in $Skipped) {
            $lines.Add("| $($row.WorkloadGroup) | $($row.ScenarioName) | $($row.DatasetMode) | $($row.DatasetSize) | $($row.Reason) |")
        }
    }
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-FRFilterCount {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][ValidateSet("CPUWhereObject", "PSAccelWhereObject")][string]$Method,
        [Parameter(Mandatory)][string]$PredicateExpression
    )
    $predicate = [scriptblock]::Create($PredicateExpression)
    if ($Method -eq "CPUWhereObject") {
        $result = @($Data | Where-Object $predicate)
    }
    else {
        $result = @($Data | PSA_Where-Object $predicate)
    }
    $count = @($result).Count
    $result = $null
    return [int]$count
}

function Invoke-FRObservation {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$PlanRow,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][bool]$Warmup,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string]$PSAccelCommit
    )
    $procBefore = Get-Process -Id $PID
    $gcBefore = @(0, 1, 2 | ForEach-Object { [GC]::CollectionCount($_) })
    $nvidiaBefore = Get-FCNvidiaTelemetry
    $start = (Get-Date).ToUniversalTime()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $count = $null
    $exception = $null
    try {
        $count = Invoke-FRFilterCount -Data $Data -Method $PlanRow.Method -PredicateExpression $PlanRow.PredicateExpression
    }
    catch {
        $exception = [pscustomobject]@{
            Message = $_.Exception.Message
            Type = $_.Exception.GetType().FullName
            ScriptStackTrace = $_.ScriptStackTrace
        }
    }
    $sw.Stop()
    $end = (Get-Date).ToUniversalTime()
    $procAfter = Get-Process -Id $PID
    $gcAfter = @(0, 1, 2 | ForEach-Object { [GC]::CollectionCount($_) })
    $nvidiaAfter = Get-FCNvidiaTelemetry
    $matched = ($null -ne $count -and [int]$count -eq [int]$ExpectedCount)

    $result = [pscustomobject]@{
        RunId = $RunId
        EnvironmentLabel = $Environment.EnvironmentLabel
        EnvironmentType = $Environment.EnvironmentType
        MachineName = 'benchmark-host'
        TimestampStart = $start.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        TimestampEnd = $end.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        StopwatchElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        WorkloadGroup = $PlanRow.WorkloadGroup
        ScenarioName = $PlanRow.ScenarioName
        DatasetMode = $PlanRow.DatasetMode
        DatasetSize = [int]$PlanRow.DatasetSize
        Distribution = $PlanRow.Distribution
        PredicateName = $PlanRow.PredicateName
        PredicateExpression = $PlanRow.PredicateExpression
        SelectivityLabel = $PlanRow.SelectivityLabel
        Trial = [int]$PlanRow.Trial
        Method = $PlanRow.Method
        Warmup = $Warmup
        ResultCount = $count
        ExpectedCount = $ExpectedCount
        CountMatchesExpected = $matched
        OfficialAnalysisEligible = -not $Warmup
        BaselineIsNativeWhereObject = ($PlanRow.Method -eq "CPUWhereObject")
        PSAccelCommit = $PSAccelCommit
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        GPUName = $Environment.GPU.PrimaryName
        GPUDriverVersion = $Environment.GPU.DriverVersion
        CPUModel = $Environment.CPUModel
        RAMGB = $Environment.RAMGB
        WindowsBuild = $Environment.WindowsBuild
        WorkingSetBefore = $procBefore.WorkingSet64
        WorkingSetAfter = $procAfter.WorkingSet64
        GC0Before = $gcBefore[0]
        GC1Before = $gcBefore[1]
        GC2Before = $gcBefore[2]
        GC0After = $gcAfter[0]
        GC1After = $gcAfter[1]
        GC2After = $gcAfter[2]
        NvidiaSmiBefore = $nvidiaBefore
        NvidiaSmiAfter = $nvidiaAfter
        Exception = $exception
    }

    $result = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    return [pscustomobject]$result
}

function Invoke-FRValidatedObservation {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$PlanRow,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][bool]$Warmup,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string]$PSAccelCommit
    )
    $procBefore = Get-Process -Id $PID
    $gcBefore = @(0, 1, 2 | ForEach-Object { [GC]::CollectionCount($_) })
    $nvidiaBefore = Get-FCNvidiaTelemetry
    $start = (Get-Date).ToUniversalTime()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $count = $null
    $exception = $null
    try {
        $count = Invoke-FRFilterCount -Data $Data -Method $PlanRow.Method -PredicateExpression $PlanRow.PredicateExpression
    }
    catch {
        $exception = [pscustomobject]@{
            Message = $_.Exception.Message
            Type = $_.Exception.GetType().FullName
            ScriptStackTrace = $_.ScriptStackTrace
        }
    }
    $sw.Stop()
    $end = (Get-Date).ToUniversalTime()
    $procAfter = Get-Process -Id $PID
    $gcAfter = @(0, 1, 2 | ForEach-Object { [GC]::CollectionCount($_) })
    $nvidiaAfter = Get-FCNvidiaTelemetry
    $matched = ($null -ne $count -and [int]$count -eq [int]$ExpectedCount)

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    return [pscustomobject]@{
        RunId = $RunId
        EnvironmentLabel = $Environment.EnvironmentLabel
        EnvironmentType = $Environment.EnvironmentType
        MachineName = 'benchmark-host'
        TimestampStart = $start.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        TimestampEnd = $end.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        StopwatchElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        WorkloadGroup = $PlanRow.WorkloadGroup
        ScenarioName = $PlanRow.ScenarioName
        DatasetMode = $PlanRow.DatasetMode
        DatasetSize = [int]$PlanRow.DatasetSize
        Distribution = $PlanRow.Distribution
        PredicateName = $PlanRow.PredicateName
        PredicateExpression = $PlanRow.PredicateExpression
        SelectivityLabel = $PlanRow.SelectivityLabel
        Trial = [int]$PlanRow.Trial
        Method = $PlanRow.Method
        Warmup = $Warmup
        ResultCount = $count
        ExpectedCount = $ExpectedCount
        CountMatchesExpected = $matched
        OfficialAnalysisEligible = -not $Warmup
        BaselineIsNativeWhereObject = ($PlanRow.Method -eq "CPUWhereObject")
        PSAccelCommit = $PSAccelCommit
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        GPUName = $Environment.GPU.PrimaryName
        GPUDriverVersion = $Environment.GPU.DriverVersion
        CPUModel = $Environment.CPUModel
        RAMGB = $Environment.RAMGB
        WindowsBuild = $Environment.WindowsBuild
        WorkingSetBefore = $procBefore.WorkingSet64
        WorkingSetAfter = $procAfter.WorkingSet64
        GC0Before = $gcBefore[0]
        GC1Before = $gcBefore[1]
        GC2Before = $gcBefore[2]
        GC0After = $gcAfter[0]
        GC1After = $gcAfter[1]
        GC2After = $gcAfter[2]
        NvidiaSmiBefore = $nvidiaBefore
        NvidiaSmiAfter = $nvidiaAfter
        Exception = $exception
    }
}

function Test-FRValidation {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$OutputRoot
    )
    New-FCDirectory -Path $OutputRoot
    $repoPath = [string]$Config.PSAccelRepoPath
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-FRCheck {
        param([string]$Name, [bool]$Required, [bool]$Passed, [object]$Detail)
        $checks.Add([pscustomobject]@{
            Name = $Name
            Required = $Required
            Passed = $Passed
            Detail = if ($null -eq $Detail) { "" } else { (@($Detail) -join " ") }
        })
    }

    $envMeta = Get-FCEnvironmentMetadata -RepoPath $repoPath
    $envMeta | Add-Member -NotePropertyName EnvironmentLabel -NotePropertyValue ([string]$Config.EnvironmentLabel) -Force
    $git = Get-FCGitState -RepoPath $repoPath

    Add-FRCheck -Name "Windows PowerShell 5.1" -Required ([bool]$Config.RequireWindowsPowerShell51) -Passed ((-not [bool]$Config.RequireWindowsPowerShell51) -or $PSVersionTable.PSVersion.Major -eq 5) -Detail $PSVersionTable.PSVersion.ToString()
    Add-FRCheck -Name "Bare metal" -Required ([bool]$Config.RequireBareMetal) -Passed ((-not [bool]$Config.RequireBareMetal) -or $envMeta.EnvironmentType -eq "BareMetal") -Detail $envMeta.EnvironmentType
    Add-FRCheck -Name "NVIDIA GPU" -Required ([bool]$Config.RequireNvidiaGpu) -Passed ((-not [bool]$Config.RequireNvidiaGpu) -or [bool]$envMeta.GPU.HasNvidia) -Detail $envMeta.GPU.PrimaryName
    Add-FRCheck -Name "No Microsoft Basic Display fallback" -Required ([bool]$Config.RequireNvidiaGpu) -Passed (-not [bool]$envMeta.GPU.HasBasicDisplay) -Detail "BasicDisplay=$($envMeta.GPU.HasBasicDisplay)"
    Add-FRCheck -Name "Native Where-Object baseline available" -Required $true -Passed ([bool](Get-Command Where-Object -ErrorAction SilentlyContinue)) -Detail "No optimized CPU baseline is used."
    Add-FRCheck -Name "Expected PSAccel commit" -Required $true -Passed ($git.Commit -eq [string]$Config.ExpectedPSAccelCommit) -Detail "Actual=$($git.Commit); Expected=$($Config.ExpectedPSAccelCommit)"
    Add-FRCheck -Name "Repository clean" -Required (-not ([bool]$Config.AllowDirtyRepo -or [bool]$AllowDirtyRepo)) -Passed ((-not [bool]$git.IsDirty) -or [bool]$Config.AllowDirtyRepo -or [bool]$AllowDirtyRepo) -Detail $git.Status

    $modulePath = ""
    try {
        $modulePath = Import-FCPSAccel -RepoPath $repoPath
        Add-FRCheck -Name "PSAccel imports" -Required $true -Passed $true -Detail $modulePath
        Add-FRCheck -Name "PSA_Where-Object command available" -Required $true -Passed ([bool](Get-Command PSA_Where-Object -ErrorAction SilentlyContinue)) -Detail "Command found."
    }
    catch {
        Add-FRCheck -Name "PSAccel imports" -Required $true -Passed $false -Detail $_.Exception.Message
        Add-FRCheck -Name "PSA_Where-Object command available" -Required $true -Passed $false -Detail "Import failed."
    }

    try {
        $tinyMode = Get-FRDefaultDatasetMode -Config $Config
        $tiny = New-FRDataset -DatasetSize 1000 -DatasetMode $tinyMode
        $expr = '$_.Offset -ne 3 -and $_.Score -le 3'
        $cpu = Invoke-FRFilterCount -Data $tiny -Method CPUWhereObject -PredicateExpression $expr
        $gpu = Invoke-FRFilterCount -Data $tiny -Method PSAccelWhereObject -PredicateExpression $expr
        Add-FRCheck -Name "Tiny CPU count" -Required $true -Passed ($cpu -ge 0) -Detail "Count=$cpu"
        Add-FRCheck -Name "Tiny PSAccel count" -Required $true -Passed ($gpu -ge 0) -Detail "Count=$gpu"
        Add-FRCheck -Name "Tiny counts match" -Required $true -Passed ($cpu -eq $gpu) -Detail "CPU=$cpu; PSAccel=$gpu"
    }
    catch {
        Add-FRCheck -Name "Tiny counts match" -Required $true -Passed $false -Detail $_.Exception.Message
    }

    $requiredFailures = @($checks | Where-Object { [bool]$_.Required -and -not [bool]$_.Passed })
    $report = [pscustomobject]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        Passed = ($requiredFailures.Count -eq 0)
        RequiredFailureCount = $requiredFailures.Count
        Environment = $envMeta
        Git = $git
        ModulePath = $modulePath
        Checks = $checks.ToArray()
    }
    Write-FCJson -InputObject $report -Path (Join-Path $OutputRoot "framework_replacement_validation.json") -Depth 28

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Framework Replacement Validation")
    $md.Add("")
    $md.Add("- Passed: $($report.Passed)")
    $md.Add("- Environment: $($envMeta.EnvironmentType)")
    $md.Add("- GPU: $($envMeta.GPU.PrimaryName)")
    $md.Add("- Commit: $($git.Commit)")
    $md.Add("")
    $md.Add("| Check | Required | Passed | Detail |")
    $md.Add("|---|---|---|---|")
    foreach ($check in $checks) {
        $md.Add("| $($check.Name) | $($check.Required) | $($check.Passed) | $(([string]$check.Detail).Replace('|','/')) |")
    }
    $md | Set-Content -LiteralPath (Join-Path $OutputRoot "framework_replacement_validation.md") -Encoding UTF8
    if ($requiredFailures.Count -gt 0) { throw "Required validation failed: $($requiredFailures.Name -join ', ')" }
    return $report
}

function Write-FRAnalysis {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][object[]]$Observations
    )
    $analysis = New-FCAnalysis -Observations $Observations
    $analysis.Descriptive | Export-Csv -NoTypeInformation -Path (Join-Path $RunRoot "framework_replacement_summary.csv")
    Write-FCJson -InputObject $analysis.Descriptive -Path (Join-Path $RunRoot "framework_replacement_summary.json") -Depth 20
    $analysis.Comparisons | Export-Csv -NoTypeInformation -Path (Join-Path $RunRoot "framework_replacement_comparison.csv")
    Write-FCJson -InputObject $analysis.Comparisons -Path (Join-Path $RunRoot "framework_replacement_comparison.json") -Depth 20

    $comparisons = @($analysis.Comparisons)
    $improved = @($comparisons | Where-Object { [System.Convert]::ToBoolean($_.PSAccelMeanLower) })
    $primary = @($comparisons | Where-Object { $_.WorkloadGroup -eq "PrimaryFrameworkWorkloads" })
    $primaryImproved = @($primary | Where-Object { [System.Convert]::ToBoolean($_.PSAccelMeanLower) })
    $boundary = @($comparisons | Where-Object { $_.WorkloadGroup -eq "BoundaryWorkloads" })
    $boundaryImproved = @($boundary | Where-Object { [System.Convert]::ToBoolean($_.PSAccelMeanLower) })
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add("# Framework Replacement Official Report")
    $report.Add("")
    $report.Add("This run evaluates PSAccel as a framework replacement for native PowerShell `Where-Object`. The CPU condition is the native baseline and is not optimized beyond out-of-box `Where-Object`.")
    $report.Add("")
    $report.Add("- Official comparisons: $($comparisons.Count)")
    $report.Add("- Comparisons where PSAccel mean was lower: $($improved.Count)")
    $report.Add("- Primary framework comparisons where PSAccel mean was lower: $($primaryImproved.Count) of $($primary.Count)")
    $report.Add("- Boundary comparisons where PSAccel mean was lower: $($boundaryImproved.Count) of $($boundary.Count)")
    $report.Add("")
    $report.Add("| Workload group | Scenario | Dataset mode | Size | CPU mean ms | PSAccel mean ms | Reduction % | Speedup | PSAccel lower mean |")
    $report.Add("|---|---|---|---:|---:|---:|---:|---:|---|")
    foreach ($row in $comparisons) {
        $report.Add("| $($row.WorkloadGroup) | $($row.ScenarioName) | $($row.DatasetMode) | $($row.DatasetSize) | $($row.CPU_MeanMs) | $($row.PSAccel_MeanMs) | $($row.PercentReduction) | $($row.SpeedupRatio) | $($row.PSAccelMeanLower) |")
    }
    $report.Add("")
    $report.Add("## Framework Interpretation")
    $report.Add("")
    $report.Add("PSAccel's CPU-side parsing, property projection, GPU staging, dispatch, readback, and result return are included in the measured PSAccel framework condition. Results should be phrased as PSAccel reducing execution time compared with native `Where-Object` for the specified workload.")
    $report | Set-Content -LiteralPath (Join-Path $RunRoot "framework_replacement_report.md") -Encoding UTF8
}

function Invoke-FRFinalOfficial {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ConfigPathValue,
        [Parameter(Mandatory)][string]$OutputRoot
    )
    if ([int]$Config.TrialsPerMethod -lt [int]$Config.MinimumApprovedTrialsPerMethod) {
        throw "TrialsPerMethod is below the approved minimum."
    }

    Copy-Item -LiteralPath $ConfigPathValue -Destination (Join-Path $OutputRoot "framework_replacement_config.input.json") -Force
    $transcript = Join-Path $OutputRoot "framework_replacement_transcript.txt"
    Start-Transcript -Path $transcript -Force | Out-Null
    $transcriptActive = $true
    $status = "ABORTED_TECHNICAL_FAILURE"
    $errorRecord = $null
    try {
        $validation = Test-FRValidation -Config $Config -OutputRoot $OutputRoot
        $repoPath = [string]$Config.PSAccelRepoPath
        $git = Get-FCGitState -RepoPath $repoPath
        $environment = Get-FCEnvironmentMetadata -RepoPath $repoPath
        $environment | Add-Member -NotePropertyName EnvironmentLabel -NotePropertyValue ([string]$Config.EnvironmentLabel) -Force

        $matrix = Resolve-FRMatrix -Config $Config
        $skipped = Resolve-FRSkippedScenarios -Config $Config
        $plan = New-FRRunPlan -Matrix $matrix -TrialsPerMethod ([int]$Config.TrialsPerMethod) -RandomSeed ([int]$Config.RandomSeed)
        $runId = Split-Path -Leaf $OutputRoot
        Write-FRMatrixMarkdown -Matrix $matrix -Path (Join-Path $OutputRoot "framework_replacement_workload_matrix.md")
        Write-FRSkippedMarkdown -Skipped $skipped -Path (Join-Path $OutputRoot "framework_replacement_skipped_scenarios.md")
        $skipped | Export-Csv -NoTypeInformation -Path (Join-Path $OutputRoot "framework_replacement_skipped_scenarios.csv")
        Write-FCJson -InputObject $skipped -Path (Join-Path $OutputRoot "framework_replacement_skipped_scenarios.json") -Depth 12
        $plan | Export-Csv -NoTypeInformation -Path (Join-Path $OutputRoot "framework_replacement_run_plan.csv")
        Write-FCJson -InputObject $plan -Path (Join-Path $OutputRoot "framework_replacement_run_plan.json") -Depth 18
        Write-FCJson -InputObject $environment -Path (Join-Path $OutputRoot "framework_replacement_environment.json") -Depth 28
        Write-FCJson -InputObject ([pscustomobject]@{
            RunId = $runId
            CreatedUtc = (Get-Date).ToUniversalTime().ToString("o")
            Config = $Config
            ResolvedMatrix = $matrix
            PredeclaredSkippedWorkloadTiers = $skipped
            ExpectedOfficialObservations = $plan.Count
            Validation = $validation
        }) -Path (Join-Path $OutputRoot "framework_replacement_config.resolved.json") -Depth 32

        $observations = New-Object System.Collections.Generic.List[object]
        $warmups = New-Object System.Collections.Generic.List[object]
        $expectedRows = New-Object System.Collections.Generic.List[object]

        foreach ($datasetGroup in ($matrix | Sort-Object DatasetMode, DatasetSize | Group-Object DatasetMode, DatasetSize)) {
            $firstScenario = @($datasetGroup.Group) | Select-Object -First 1
            $size = [int]$firstScenario.DatasetSize
            $datasetMode = [string]$firstScenario.DatasetMode
            Write-FCMessage "Generating repository-style dataset mode=$datasetMode size=$size"
            $datasetTimer = [Diagnostics.Stopwatch]::StartNew()
            $data = New-FRDataset -DatasetSize $size -DatasetMode $datasetMode
            $datasetTimer.Stop()
            Write-FCJson -InputObject ([pscustomobject]@{
                DatasetSize = $size
                DatasetMode = $datasetMode
                GenerationMs = [math]::Round($datasetTimer.Elapsed.TotalMilliseconds, 3)
                Records = $data.Count
            }) -Path (Join-Path $OutputRoot ("dataset-{0}-{1}-metadata.json" -f $datasetMode, $size)) -Depth 10

            foreach ($scenario in @($datasetGroup.Group)) {
                Write-FCMessage "Computing expected count scenario=$($scenario.ScenarioName) size=$size"
                $expectedCount = Invoke-FRFilterCount -Data $data -Method CPUWhereObject -PredicateExpression $scenario.PredicateExpression
                $expectedRows.Add([pscustomobject]@{
                    ScenarioName = $scenario.ScenarioName
                    DatasetSize = $size
                    PredicateExpression = $scenario.PredicateExpression
                    ExpectedCount = $expectedCount
                    SelectivityPercent = [math]::Round(($expectedCount / [double]$size) * 100.0, 4)
                    ExpectedCountSource = "Native Where-Object validation pass, not official timing."
                })
                $expectedRows.ToArray() | Export-Csv -NoTypeInformation -Path (Join-Path $OutputRoot "framework_replacement_expected_counts.csv")

                foreach ($method in @("CPUWhereObject", "PSAccelWhereObject")) {
                    for ($warmup = 1; $warmup -le [int]$Config.WarmupRuns; $warmup++) {
                        $warmPlan = $scenario | Select-Object *
                        $warmPlan | Add-Member -NotePropertyName Trial -NotePropertyValue $warmup -Force
                        $warmPlan | Add-Member -NotePropertyName Method -NotePropertyValue $method -Force
                        Write-FCMessage "Warmup scenario=$($scenario.ScenarioName) size=$size method=$method warmup=$warmup"
                        $warm = Invoke-FRValidatedObservation -Data $data -PlanRow $warmPlan -ExpectedCount $expectedCount -Warmup $true -RunId $runId -Environment $environment -PSAccelCommit $git.Commit
                        $warmups.Add($warm)
                        $warmups.ToArray() | Export-Csv -NoTypeInformation -Path (Join-Path $OutputRoot "framework_replacement_warmups.csv")
                        if (-not $warm.CountMatchesExpected -or $warm.Exception) {
                            throw "Warmup failed scenario=$($scenario.ScenarioName) size=$size method=$method"
                        }
                    }
                }

                $matchingPlan = @($plan | Where-Object {
                    $_.ScenarioName -eq $scenario.ScenarioName -and [int]$_.DatasetSize -eq $size -and $_.DatasetMode -eq $datasetMode
                } | Sort-Object Sequence)
                foreach ($planRow in $matchingPlan) {
                    Write-FCMessage "Official observation seq=$($planRow.Sequence) scenario=$($planRow.ScenarioName) size=$size method=$($planRow.Method) trial=$($planRow.Trial)"
                    $obs = Invoke-FRValidatedObservation -Data $data -PlanRow $planRow -ExpectedCount $expectedCount -Warmup $false -RunId $runId -Environment $environment -PSAccelCommit $git.Commit
                    $observations.Add($obs)
                    $observations.ToArray() | Export-Csv -NoTypeInformation -Path (Join-Path $OutputRoot "framework_replacement_observations.csv")
                    if (-not $obs.CountMatchesExpected -or $obs.Exception) {
                        throw "Official observation failed scenario=$($planRow.ScenarioName) size=$size method=$($planRow.Method) trial=$($planRow.Trial)"
                    }
                }
            }

            $data = $null
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        }

        $rows = $observations.ToArray()
        if ($rows.Count -ne $plan.Count) {
            throw "Expected $($plan.Count) official observations, got $($rows.Count)."
        }
        Write-FCJson -InputObject $rows -Path (Join-Path $OutputRoot "framework_replacement_observations.json") -Depth 24
        Write-FCJson -InputObject $expectedRows.ToArray() -Path (Join-Path $OutputRoot "framework_replacement_expected_counts.json") -Depth 18
        Write-FRAnalysis -RunRoot $OutputRoot -Observations $rows
        $status = "COMPLETED_FRAMEWORK_REPLACEMENT_OFFICIAL"
    }
    catch {
        $errorRecord = [pscustomobject]@{
            Message = $_.Exception.Message
            Type = $_.Exception.GetType().FullName
            ScriptStackTrace = $_.ScriptStackTrace
            CapturedUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-FCJson -InputObject $errorRecord -Path (Join-Path $OutputRoot "framework_replacement_error.json") -Depth 12
        throw
    }
    finally {
        Write-FCJson -InputObject ([pscustomobject]@{
            Status = $status
            CompletedUtc = (Get-Date).ToUniversalTime().ToString("o")
            Error = $errorRecord
            Note = "Only COMPLETED_FRAMEWORK_REPLACEMENT_OFFICIAL should be treated as official. Preserve aborted artifacts separately."
        }) -Path (Join-Path $OutputRoot "framework_replacement_status.json") -Depth 12
        if ($transcriptActive) { Stop-Transcript | Out-Null }
    }
}

$resolvedConfigPath = Resolve-FRConfigPath -Path $ConfigPath
$config = Read-FRConfig -Path $resolvedConfigPath

switch ($Mode) {
    "ValidateOnly" {
        $root = if ($RunRoot) { $RunRoot } else { New-FRRunRoot -Config $config }
        Test-FRValidation -Config $config -OutputRoot $root | Out-Null
        Write-Host "ValidateOnly output: $root"
    }
    "SmokeTest" {
        $root = if ($RunRoot) { $RunRoot } else { New-FRRunRoot -Config $config }
        $validation = Test-FRValidation -Config $config -OutputRoot $root
        $repoPath = [string]$config.PSAccelRepoPath
        $git = Get-FCGitState -RepoPath $repoPath
        $envMeta = Get-FCEnvironmentMetadata -RepoPath $repoPath
        $envMeta | Add-Member -NotePropertyName EnvironmentLabel -NotePropertyValue ([string]$config.EnvironmentLabel) -Force
        $smokeMode = Get-FRDefaultDatasetMode -Config $config
        $data = New-FRDataset -DatasetSize 1000 -DatasetMode $smokeMode
        $scenario = [pscustomobject]@{
            WorkloadGroup = "SmokeTest"
            ScenarioName = "Smoke_OffsetScore"
            DatasetMode = $smokeMode
            DatasetSize = 1000
            Distribution = "repository-style"
            PredicateName = "Smoke"
            PredicateExpression = '$_.Offset -ne 3 -and $_.Score -le 3'
            SelectivityLabel = "low"
        }
        $expected = Invoke-FRFilterCount -Data $data -Method CPUWhereObject -PredicateExpression $scenario.PredicateExpression
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($method in @("CPUWhereObject", "PSAccelWhereObject")) {
            $planRow = $scenario | Select-Object *
            $planRow | Add-Member -NotePropertyName Trial -NotePropertyValue 1 -Force
            $planRow | Add-Member -NotePropertyName Method -NotePropertyValue $method -Force
            $obs = Invoke-FRValidatedObservation -Data $data -PlanRow $planRow -ExpectedCount $expected -Warmup $false -RunId "SmokeTest" -Environment $envMeta -PSAccelCommit $git.Commit
            $rows.Add($obs)
            if (-not $obs.CountMatchesExpected -or $obs.Exception) { throw "SmokeTest failed for $method." }
        }
        $rows.ToArray() | Export-Csv -NoTypeInformation -Path (Join-Path $root "framework_replacement_smoke.csv")
        Write-FCJson -InputObject $rows.ToArray() -Path (Join-Path $root "framework_replacement_smoke.json") -Depth 20
        Write-Host "SmokeTest output: $root"
    }
    "FinalOfficial" {
        $root = if ($RunRoot) { $RunRoot } else { New-FRRunRoot -Config $config }
        try {
            Invoke-FRFinalOfficial -Config $config -ConfigPathValue $resolvedConfigPath -OutputRoot $root
            Write-Host "FinalOfficial output: $root"
        }
        catch {
            if ([bool]$config.ZipArtifacts) {
                try { Save-FCArtifactManifest -RunRoot $root -CreateZip | Out-Null } catch { Write-Warning $_.Exception.Message }
            }
            throw
        }
    }
    "AnalyzeOnly" {
        if (-not $RunRoot) { throw "AnalyzeOnly requires -RunRoot." }
        $observationsPath = Join-Path $RunRoot "framework_replacement_observations.csv"
        if (-not (Test-Path -LiteralPath $observationsPath)) { throw "Observations not found: $observationsPath" }
        $rows = @(Import-Csv -LiteralPath $observationsPath)
        Write-FRAnalysis -RunRoot $RunRoot -Observations $rows
        Write-Host "AnalyzeOnly output: $RunRoot"
    }
    "ArchiveOnly" {
        if (-not $RunRoot) { throw "ArchiveOnly requires -RunRoot." }
        $zip = Save-FCArtifactManifest -RunRoot $RunRoot -CreateZip
        Write-Host "Archive complete: $($zip.Path)"
        Write-Host "SHA256: $($zip.SHA256)"
    }
    "SummarizeOnly" {
        if (-not $RunRoot) { throw "SummarizeOnly requires -RunRoot." }
        Import-Csv -LiteralPath (Join-Path $RunRoot "framework_replacement_comparison.csv") | Format-Table -AutoSize
    }
}
