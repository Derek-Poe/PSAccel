#requires -Version 5.1
<#
Shared functions for the PSAccel final framework capture toolkit.

Dissertation relevance: this library centralizes environment validation,
predeclared workload resolution, dataset generation, official observation
timing, result-count validation, descriptive statistics, and artifact hashing.
The official comparison remains native Where-Object versus PSA_Where-Object.
#>

Set-StrictMode -Version Latest

class SyntheticRecord {
    [int]$Id
    [int]$Value
    [int]$Group
    [int]$ValueA
    [int]$ValueB
    [int]$ValueC

    SyntheticRecord(
        [int]$id,
        [int]$value,
        [int]$group,
        [int]$valueA,
        [int]$valueB,
        [int]$valueC
    ) {
        $this.Id = $id
        $this.Value = $value
        $this.Group = $group
        $this.ValueA = $valueA
        $this.ValueB = $valueB
        $this.ValueC = $valueC
    }
}

function Write-FCMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "s"), $Message)
}

function New-FCDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-FCJson {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 24
    )
    $directory = Split-Path -Parent $Path
    if ($directory) { New-FCDirectory -Path $directory }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($InputObject | ConvertTo-Json -Depth $Depth), $utf8)
}

function Get-FCProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Read-FCConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Resolve-FCConfigPath {
    param([string]$ConfigPath, [string]$ScriptRoot)
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return (Resolve-Path -LiteralPath $ConfigPath).Path
    }
    $preferred = Join-Path $ScriptRoot "final-capture-config.json"
    if (Test-Path -LiteralPath $preferred) { return (Resolve-Path -LiteralPath $preferred).Path }
    return (Resolve-Path -LiteralPath (Join-Path $ScriptRoot "final-capture-config.example.json")).Path
}

function Get-FCEnvironmentType {
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $text = @(
        if ($computer) { $computer.Manufacturer }
        if ($computer) { $computer.Model }
        if ($bios) { $bios.Manufacturer }
        if ($bios) { $bios.SMBIOSBIOSVersion }
    ) -join " "
    if ($text -match "QEMU|KVM|VirtualBox|VMware|Hyper-V|Virtual Machine|Bochs|Xen") {
        return "VM"
    }
    return "BareMetal"
}

function Get-FCGitState {
    param([Parameter(Mandatory)][string]$RepoPath)
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $git) {
        return [pscustomobject]@{
            Available = $false
            Commit = ""
            IsDirty = $null
            Status = "git not found"
            Branch = "not measured"
        }
    }
    if (-not (Test-Path -LiteralPath $RepoPath)) {
        return [pscustomobject]@{
            Available = $true
            Commit = ""
            IsDirty = $null
            Status = "repo path not found"
            Branch = "not measured"
        }
    }
    Push-Location $RepoPath
    try {
        $commit = (& $git.Source rev-parse HEAD 2>$null)
        $branch = (& $git.Source rev-parse --abbrev-ref HEAD 2>$null)
        $status = @(& $git.Source status --porcelain 2>$null)
        return [pscustomobject]@{
            Available = $true
            Commit = [string]$commit
            IsDirty = $status.Count -gt 0
            Status = ($status -join [Environment]::NewLine)
            Branch = [string]$branch
        }
    }
    finally {
        Pop-Location
    }
}

function Import-FCPSAccel {
    param([Parameter(Mandatory)][string]$RepoPath)
    if (-not (Test-Path -LiteralPath $RepoPath)) {
        throw "PSAccel repository path not found: $RepoPath"
    }
    $manifest = Get-ChildItem -LiteralPath $RepoPath -Filter "PSAccel.psd1" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $module = if ($manifest) {
        $manifest.FullName
    }
    else {
        $psm1 = Get-ChildItem -LiteralPath $RepoPath -Filter "PSAccel.psm1" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($psm1) { $psm1.FullName } else { $null }
    }
    if (-not $module) {
        throw "Could not locate PSAccel.psd1 or PSAccel.psm1 under $RepoPath"
    }

    $previousDotNetDirectory = [System.IO.Directory]::GetCurrentDirectory()
    Push-Location $RepoPath
    try {
        # The approved PSAccel commit reads source files by relative path during
        # import, so set both PowerShell and .NET current directories.
        [System.IO.Directory]::SetCurrentDirectory((Resolve-Path -LiteralPath $RepoPath).Path)
        Import-Module $module -Force -ErrorAction Stop
        if (-not (Get-Command PSA_Where-Object -ErrorAction SilentlyContinue)) {
            throw "PSA_Where-Object was not available after importing PSAccel."
        }
    }
    finally {
        Pop-Location
        [System.IO.Directory]::SetCurrentDirectory($previousDotNetDirectory)
    }
    return $module
}

function Get-FCNvidiaTelemetry {
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $smi) { $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue }
    if (-not $smi) {
        return [pscustomobject]@{ Status = "not measured"; Reason = "nvidia-smi not found" }
    }
    $query = "--query-gpu=timestamp,name,driver_version,pstate,utilization.gpu,utilization.memory,memory.used,power.draw,clocks.sm,clocks.mem"
    try {
        $raw = & $smi.Source $query --format=csv,noheader,nounits 2>$null
        return [pscustomobject]@{ Status = "measured"; Path = $smi.Source; Raw = [string]$raw }
    }
    catch {
        return [pscustomobject]@{ Status = "not measured"; Reason = $_.Exception.Message; Path = $smi.Source }
    }
}

function Get-FCGpuInfo {
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Select-Object Name, DriverVersion, AdapterRAM, PNPDeviceID)
    $nvidia = @($controllers | Where-Object { $_.Name -match "NVIDIA" })
    $basic = @($controllers | Where-Object { $_.Name -match "Microsoft Basic Display" })
    return [pscustomobject]@{
        Controllers = $controllers
        NvidiaControllers = $nvidia
        BasicDisplayAdapters = $basic
        HasNvidia = $nvidia.Count -gt 0
        HasBasicDisplay = $basic.Count -gt 0
        PrimaryName = if ($nvidia.Count -gt 0) { $nvidia[0].Name } elseif ($controllers.Count -gt 0) { $controllers[0].Name } else { "not measured" }
        DriverVersion = if ($nvidia.Count -gt 0) { $nvidia[0].DriverVersion } elseif ($controllers.Count -gt 0) { $controllers[0].DriverVersion } else { "not measured" }
        NvidiaTelemetry = Get-FCNvidiaTelemetry
    }
}

function Get-FCWindowsUpdatePendingReboot {
    $sessionManager = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    $pendingRenameProperty = if ($sessionManager) { $sessionManager.PSObject.Properties["PendingFileRenameOperations"] } else { $null }
    $pendingRename = if ($pendingRenameProperty) { $pendingRenameProperty.Value } else { @() }
    return [pscustomobject]@{
        CBS = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        WindowsUpdate = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        PendingFileRename = ($null -ne $pendingRename -and @($pendingRename | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
        PendingFileRenameOperations = @($pendingRename | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}

function Get-FCPowerSettings {
    $active = (powercfg /GETACTIVESCHEME 2>$null) -join " "
    $hibernate = (powercfg /A 2>$null) -join [Environment]::NewLine
    return [pscustomobject]@{
        ActiveScheme = if ($active) { $active } else { "not measured" }
        SleepStateReport = if ($hibernate) { $hibernate } else { "not measured" }
    }
}

function Get-FCEnvironmentMetadata {
    param([Parameter(Mandatory)][string]$RepoPath)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $gpu = Get-FCGpuInfo
    return [pscustomobject]@{
        CapturedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        MachineName = 'benchmark-host'
        EnvironmentType = Get-FCEnvironmentType
        ExecutionUser = 'benchmark-user'
        ProcessId = $PID
        SessionId = (Get-Process -Id $PID).SessionId
        WindowsBuild = if ($os) { $os.Version } else { "not measured" }
        WindowsCaption = if ($os) { $os.Caption } else { "not measured" }
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PSEdition = [string]$PSVersionTable.PSEdition
        PowerShell7 = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { (& pwsh.exe -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null) } else { "not installed" }
        DotNetVersion = [System.Environment]::Version.ToString()
        CPUModel = if ($cpu) { $cpu.Name } else { "not measured" }
        CPUCores = if ($cpu) { $cpu.NumberOfCores } else { $null }
        CPUThreads = if ($cpu) { $cpu.NumberOfLogicalProcessors } else { $null }
        RAMBytes = if ($computer) { [int64]$computer.TotalPhysicalMemory } else { $null }
        RAMGB = if ($computer) { [math]::Round(([int64]$computer.TotalPhysicalMemory / 1GB), 2) } else { $null }
        GPU = $gpu
        Power = Get-FCPowerSettings
        WindowsUpdatePendingReboot = Get-FCWindowsUpdatePendingReboot
        Git = Get-FCGitState -RepoPath $RepoPath
        Disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Select-Object Model, Size, InterfaceType)
    }
}

function New-FCPSCustomDataset {
    param(
        [Parameter(Mandatory)][int]$DatasetSize,
        [int]$Seed = 20260609
    )
    $list = New-Object "System.Collections.Generic.List[object]"
    for ($i = 0; $i -lt $DatasetSize; $i++) {
        $value = $i % 100
        $list.Add([pscustomobject]@{
            Id = $i
            Value = $value
            Group = $i % 5
            ValueA = $i % 100
            ValueB = (($i * 7) + 13 + ($Seed % 17)) % 100
            ValueC = (($i * 11) + 17 + ($Seed % 19)) % 100
            Severity = $i % 10
            Count = ($i * 3) % 1000
            Score = (($i * 17) + 11 + ($Seed % 23)) % 100
            SizeMB = ($i % 500) + 1
            AgeDays = $i % 365
            Weight = ($i * 13) % 100
            Ratio = [double]($value / 100.0)
        })
    }
    return $list.ToArray()
}

function New-FCSyntheticRecordDataset {
    param(
        [Parameter(Mandatory)][int]$DatasetSize,
        [int]$Seed = 20260609
    )
    $list = New-Object "System.Collections.Generic.List[SyntheticRecord]"
    for ($i = 0; $i -lt $DatasetSize; $i++) {
        $list.Add([SyntheticRecord]::new(
            $i,
            ($i % 100),
            ($i % 5),
            ($i % 100),
            ((($i * 7) + 13 + ($Seed % 17)) % 100),
            ((($i * 11) + 17 + ($Seed % 19)) % 100)
        ))
    }
    return $list.ToArray()
}

function New-FCOfficialDataset {
    param(
        [Parameter(Mandatory)][ValidateSet("PSCustomObject", "SyntheticRecordClass")][string]$DatasetMode,
        [Parameter(Mandatory)][int]$DatasetSize,
        [int]$Seed = 20260609
    )
    if ($DatasetMode -eq "PSCustomObject") {
        return New-FCPSCustomDataset -DatasetSize $DatasetSize -Seed $Seed
    }
    return New-FCSyntheticRecordDataset -DatasetSize $DatasetSize -Seed $Seed
}

function Invoke-FCFilterCount {
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

function Get-FCExpectedCount {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)][int]$DatasetSize
    )
    $source = "CPU Where-Object pre-run expected count"
    $expected = $null
    $calc = Get-FCProperty -Object $Scenario -Name "ExpectedCountFormula" -Default "Precompute"
    if ($calc -eq "ModuloValueGt95") {
        $expected = [int]([math]::Floor($DatasetSize / 100) * 4)
        $source = "direct modulo Value > 95 calculation"
    }
    elseif ($calc -eq "ModuloValueGt50") {
        $expected = [int]([math]::Floor($DatasetSize / 100) * 49)
        $source = "direct modulo Value > 50 calculation"
    }
    else {
        $expected = Invoke-FCFilterCount -Data $Data -Method "CPUWhereObject" -PredicateExpression $Scenario.PredicateExpression
    }
    return [pscustomobject]@{
        ExpectedCount = [int]$expected
        ExpectedCountSource = $source
        SelectivityPercent = [math]::Round(([int]$expected / [double]$DatasetSize) * 100.0, 4)
    }
}

function Resolve-FCWorkloadMatrix {
    param([Parameter(Mandatory)]$Config)
    $resolved = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $maxPSCustom = [int64](Get-FCProperty -Object $Config -Name "MaxPSCustomObjectRecords" -Default 1000000)

    foreach ($groupName in @("PrimaryFrameworkWorkloads", "BoundaryWorkloads")) {
        $group = Get-FCProperty -Object $Config.WorkloadMatrix -Name $groupName -Default @()
        foreach ($scenario in @($group)) {
            foreach ($size in @($scenario.DatasetSizes)) {
                $datasetMode = [string]$scenario.DatasetMode
                if ($datasetMode -eq "PSCustomObject" -and [int64]$size -gt $maxPSCustom) {
                    $skipped.Add([pscustomobject]@{
                        WorkloadGroup = $groupName
                        ScenarioName = $scenario.ScenarioName
                        DatasetMode = $datasetMode
                        DatasetSize = [int]$size
                        Reason = "predeclared memory safety threshold"
                        MaxPSCustomObjectRecords = $maxPSCustom
                        OfficialAnalysisEligible = $false
                    })
                    continue
                }
                $resolved.Add([pscustomobject]@{
                    WorkloadGroup = $groupName
                    ScenarioName = [string]$scenario.ScenarioName
                    DatasetMode = $datasetMode
                    DatasetSize = [int]$size
                    Distribution = [string]$scenario.Distribution
                    PredicateName = [string]$scenario.PredicateName
                    PredicateExpression = [string]$scenario.PredicateExpression
                    SelectivityLabel = [string]$scenario.SelectivityLabel
                    ExpectedCountFormula = [string](Get-FCProperty -Object $scenario -Name "ExpectedCountFormula" -Default "Precompute")
                    ReductionEligible = $true
                    OfficialAnalysisEligible = $true
                    DiagnosticOnly = $false
                })
            }
        }
    }

    return [pscustomobject]@{
        Resolved = $resolved.ToArray()
        Skipped = $skipped.ToArray()
    }
}

function Write-FCWorkloadMatrixMarkdown {
    param(
        [Parameter(Mandatory)][object[]]$ResolvedMatrix,
        [Parameter(Mandatory)][object[]]$SkippedScenarios,
        [Parameter(Mandatory)][string]$Path
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Official Workload Matrix")
    $lines.Add("")
    $lines.Add("This matrix was resolved and written before official observations began.")
    $lines.Add("")
    $lines.Add("| Group | Scenario | Mode | Size | Predicate | Selectivity | Eligible |")
    $lines.Add("|---|---|---|---:|---|---|---|")
    foreach ($row in $ResolvedMatrix) {
        $lines.Add("| $($row.WorkloadGroup) | $($row.ScenarioName) | $($row.DatasetMode) | $($row.DatasetSize) | `$($row.PredicateExpression)` | $($row.SelectivityLabel) | True |")
    }
    if ($SkippedScenarios.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Predeclared Skips")
        $lines.Add("")
        $lines.Add("| Group | Scenario | Mode | Size | Reason |")
        $lines.Add("|---|---|---|---:|---|")
        foreach ($skip in $SkippedScenarios) {
            $lines.Add("| $($skip.WorkloadGroup) | $($skip.ScenarioName) | $($skip.DatasetMode) | $($skip.DatasetSize) | $($skip.Reason) |")
        }
    }
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-FCRunPlan {
    param(
        [Parameter(Mandatory)][object[]]$ResolvedMatrix,
        [Parameter(Mandatory)][int]$TrialsPerMethod,
        [Parameter(Mandatory)][int]$RandomSeed
    )
    $random = New-Object System.Random($RandomSeed)
    $plan = New-Object System.Collections.Generic.List[object]
    $sequence = 0
    foreach ($scenario in $ResolvedMatrix) {
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

function Invoke-FCObservation {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$PlanRow,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][bool]$Warmup,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string]$PSAccelCommit
    )
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()

    $procBefore = Get-Process -Id $PID
    $gcBefore = @(0, 1, 2 | ForEach-Object { [GC]::CollectionCount($_) })
    $nvidiaBefore = Get-FCNvidiaTelemetry
    $start = (Get-Date).ToUniversalTime()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exception = $null
    $count = $null
    try {
        $count = Invoke-FCFilterCount -Data $Data -Method $PlanRow.Method -PredicateExpression $PlanRow.PredicateExpression
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
    $matches = ($null -ne $count -and [int]$count -eq [int]$ExpectedCount)

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
        CountMatchesExpected = $matches
        ReductionEligible = [bool]$PlanRow.OfficialAnalysisEligible
        OfficialAnalysisEligible = [bool]$PlanRow.OfficialAnalysisEligible
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

function Get-FCMean {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    return (($Values | Measure-Object -Average).Average)
}

function Get-FCStandardDeviation {
    param([double[]]$Values)
    if ($Values.Count -le 1) { return 0.0 }
    $mean = Get-FCMean -Values $Values
    $sum = 0.0
    foreach ($value in $Values) { $sum += [math]::Pow(($value - $mean), 2) }
    return [math]::Sqrt($sum / ($Values.Count - 1))
}

function Get-FCPercentile {
    param(
        [double[]]$Values,
        [Parameter(Mandatory)][double]$Percentile
    )
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }
    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $low = [math]::Floor($rank)
    $high = [math]::Ceiling($rank)
    if ($low -eq $high) { return [double]$sorted[$low] }
    $weight = $rank - $low
    return ([double]$sorted[$low] * (1.0 - $weight)) + ([double]$sorted[$high] * $weight)
}

function New-FCDescriptiveRow {
    param([Parameter(Mandatory)][object[]]$Rows)
    $times = @($Rows | ForEach-Object { [double]$_.StopwatchElapsedMs })
    $mean = Get-FCMean -Values $times
    $sd = Get-FCStandardDeviation -Values $times
    $q1 = Get-FCPercentile -Values $times -Percentile 25
    $median = Get-FCPercentile -Values $times -Percentile 50
    $q3 = Get-FCPercentile -Values $times -Percentile 75
    $ci = if ($times.Count -gt 1) { 1.96 * ($sd / [math]::Sqrt($times.Count)) } else { 0.0 }
    return [pscustomobject]@{
        WorkloadGroup = $Rows[0].WorkloadGroup
        ScenarioName = $Rows[0].ScenarioName
        DatasetMode = $Rows[0].DatasetMode
        DatasetSize = [int]$Rows[0].DatasetSize
        PredicateName = $Rows[0].PredicateName
        SelectivityLabel = $Rows[0].SelectivityLabel
        Method = $Rows[0].Method
        N = $times.Count
        MeanMs = [math]::Round($mean, 3)
        SDMs = [math]::Round($sd, 3)
        MedianMs = [math]::Round($median, 3)
        MinMs = [math]::Round((($times | Measure-Object -Minimum).Minimum), 3)
        MaxMs = [math]::Round((($times | Measure-Object -Maximum).Maximum), 3)
        IQRMs = [math]::Round(($q3 - $q1), 3)
        CI95LowerMs = [math]::Round(($mean - $ci), 3)
        CI95UpperMs = [math]::Round(($mean + $ci), 3)
        CountValidationPassed = (@($Rows | Where-Object { -not [System.Convert]::ToBoolean($_.CountMatchesExpected) }).Count -eq 0)
    }
}

function New-FCAnalysis {
    param([Parameter(Mandatory)][object[]]$Observations)
    $official = @($Observations | Where-Object {
        -not [System.Convert]::ToBoolean($_.Warmup) -and
        [System.Convert]::ToBoolean($_.OfficialAnalysisEligible)
    })
    $descriptive = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($official | Group-Object WorkloadGroup, ScenarioName, DatasetSize, Method)) {
        $descriptive.Add((New-FCDescriptiveRow -Rows @($group.Group)))
    }

    $comparisons = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($official | Group-Object WorkloadGroup, ScenarioName, DatasetSize)) {
        $rows = @($group.Group)
        $cpu = @($rows | Where-Object Method -eq "CPUWhereObject" | ForEach-Object { [double]$_.StopwatchElapsedMs })
        $gpu = @($rows | Where-Object Method -eq "PSAccelWhereObject" | ForEach-Object { [double]$_.StopwatchElapsedMs })
        if ($cpu.Count -eq 0 -or $gpu.Count -eq 0) { continue }
        $cpuMean = Get-FCMean -Values $cpu
        $gpuMean = Get-FCMean -Values $gpu
        $cpuSd = Get-FCStandardDeviation -Values $cpu
        $gpuSd = Get-FCStandardDeviation -Values $gpu
        $pooled = if (($cpu.Count + $gpu.Count - 2) -gt 0) {
            [math]::Sqrt(((($cpu.Count - 1) * [math]::Pow($cpuSd, 2)) + (($gpu.Count - 1) * [math]::Pow($gpuSd, 2))) / ($cpu.Count + $gpu.Count - 2))
        }
        else { 0.0 }
        $cohen = if ($pooled -ne 0.0) { ($cpuMean - $gpuMean) / $pooled } else { $null }
        $welchDenominator = [math]::Sqrt(([math]::Pow($cpuSd, 2) / $cpu.Count) + ([math]::Pow($gpuSd, 2) / $gpu.Count))
        $welchT = if ($welchDenominator -ne 0.0) { ($cpuMean - $gpuMean) / $welchDenominator } else { $null }
        $comparisons.Add([pscustomobject]@{
            WorkloadGroup = $rows[0].WorkloadGroup
            ScenarioName = $rows[0].ScenarioName
            DatasetMode = $rows[0].DatasetMode
            DatasetSize = [int]$rows[0].DatasetSize
            PredicateName = $rows[0].PredicateName
            SelectivityLabel = $rows[0].SelectivityLabel
            CPU_N = $cpu.Count
            PSAccel_N = $gpu.Count
            CPU_MeanMs = [math]::Round($cpuMean, 3)
            PSAccel_MeanMs = [math]::Round($gpuMean, 3)
            AbsoluteReductionMs = [math]::Round(($cpuMean - $gpuMean), 3)
            PercentReduction = [math]::Round(((($cpuMean - $gpuMean) / $cpuMean) * 100.0), 3)
            SpeedupRatio = [math]::Round(($cpuMean / $gpuMean), 4)
            PSAccelMeanLower = ($gpuMean -lt $cpuMean)
            CohenD = if ($null -ne $cohen) { [math]::Round($cohen, 4) } else { "not measured" }
            WelchT = if ($null -ne $welchT) { [math]::Round($welchT, 4) } else { "not measured" }
            WelchP = "not measured by PowerShell implementation"
            MannWhitneyU = "not measured by PowerShell implementation"
            StatisticalNote = "Use an external SciPy/R pass for exact p values if required; this table separates practical improvement from statistical significance."
        })
    }
    return [pscustomobject]@{
        Descriptive = $descriptive.ToArray()
        Comparisons = $comparisons.ToArray()
    }
}

function ConvertTo-FCMarkdownTable {
    param([Parameter(Mandatory)][object[]]$Rows)
    if ($Rows.Count -eq 0) { return @("No rows.") }
    $properties = @($Rows[0].PSObject.Properties.Name)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("| " + ($properties -join " | ") + " |")
    $lines.Add("| " + (($properties | ForEach-Object { "---" }) -join " | ") + " |")
    foreach ($row in $Rows) {
        $values = @($properties | ForEach-Object {
            $text = [string](Get-FCProperty -Object $row -Name $_ -Default "")
            $text.Replace("|", "/")
        })
        $lines.Add("| " + ($values -join " | ") + " |")
    }
    return $lines.ToArray()
}

function Save-FCArtifactManifest {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [switch]$CreateZip
    )
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $RunRoot -File -Recurse | Where-Object { $_.Name -notin @("artifact_manifest.json", "artifact_manifest.md", "sha256sums.txt") })) {
        try {
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            $relative = $file.FullName.Substring($RunRoot.Length).TrimStart("\", "/")
            $files.Add([pscustomobject]@{
                RelativePath = $relative
                Length = $file.Length
                SHA256 = $hash.Hash.ToLowerInvariant()
                HashStatus = "ok"
            })
        }
        catch {
            $files.Add([pscustomobject]@{
                RelativePath = $file.FullName.Substring($RunRoot.Length).TrimStart("\", "/")
                Length = $file.Length
                SHA256 = ""
                HashStatus = "not hashed"
                HashError = $_.Exception.Message
            })
        }
    }
    $manifest = [pscustomobject]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        RunRoot = $RunRoot
        Files = $files.ToArray()
        Zip = $null
    }
    Write-FCJson -InputObject $manifest -Path (Join-Path $RunRoot "artifact_manifest.json") -Depth 24

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Artifact Manifest")
    $md.Add("")
    $md.Add("- Run root: $RunRoot")
    $md.Add("- Generated UTC: $($manifest.GeneratedUtc)")
    $md.Add("")
    $md.Add("| File | SHA256 | Bytes |")
    $md.Add("|---|---|---:|")
    foreach ($entry in $files) {
        $md.Add("| $($entry.RelativePath) | $($entry.SHA256) | $($entry.Length) |")
    }
    $md | Set-Content -LiteralPath (Join-Path $RunRoot "artifact_manifest.md") -Encoding UTF8
    $files | ForEach-Object { "$($_.SHA256)  $($_.RelativePath)" } |
        Set-Content -LiteralPath (Join-Path $RunRoot "sha256sums.txt") -Encoding ASCII

    if ($CreateZip) {
        $zipPath = "$RunRoot.zip"
        if (Test-Path -LiteralPath $zipPath) {
            throw "Refusing to overwrite existing archive: $zipPath"
        }
        Compress-Archive -LiteralPath $RunRoot -DestinationPath $zipPath -Force
        $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.Zip = [pscustomobject]@{
            Path = $zipPath
            SHA256 = $zipHash
            Length = (Get-Item -LiteralPath $zipPath).Length
        }
        Write-FCJson -InputObject $manifest -Path (Join-Path $RunRoot "artifact_manifest.json") -Depth 24
        Add-Content -LiteralPath (Join-Path $RunRoot "sha256sums.txt") -Value "$zipHash  $(Split-Path -Leaf $zipPath)"
        return $manifest.Zip
    }
    return $null
}

function Get-FCLatestRunRoot {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Prefix = "FrameworkFinalOfficial-"
    )
    $outputRoot = [string]$Config.OutputRoot
    $root = Join-Path $outputRoot "FrameworkFinalOfficial"
    $candidate = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$Prefix*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) { throw "No run folder matching $Prefix found under $root" }
    return $candidate.FullName
}
