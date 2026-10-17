# PSAccel Framework Replacement Official Capture

This is the capture harness used for the June 2026 framework-replacement study. Its example configuration is pinned to the measured source commit, not the current maintenance version. The public copy uses synthetic host/account labels and omits disk serial numbers from environment metadata. It retains the original workload design.

The official comparison is intentionally simple:

- Native baseline: `$data | Where-Object { <numeric predicate> }`
- PSAccel framework: `$data | PSA_Where-Object { <same numeric predicate> }`

No optimized CPU loops, LINQ, compiled delegates, pre-flattened CPU arrays, typed CPU filters, or custom baseline helpers are used as official methods. If PSAccel outperforms native PowerShell because its framework performs parsing, projection, staging, GPU dispatch, readback, and result handling more efficiently, that is part of the framework result.

## Why This Fresh Run Exists

Earlier completed framework capture artifacts are preserved and remain valid evidence for their predeclared matrix. However, comparison with the repository/Desktop benchmark showed that the earlier matrix did not fully represent the workload family where PSAccel was designed to replace `Where-Object`: PSCustomObject numeric filtering with multi-clause predicates.

This run starts fresh with a predeclared matrix modeled on the repository benchmark family while adding dissertation controls:

- fixed PSAccel commit
- fixed seed
- fixed method order randomization
- repeated trials per condition
- count validation for every observation
- timestamped output folder
- archive and SHA256 hash

## Workflow

Use Windows PowerShell 5.1 on a suitable bare-metal benchmark machine. Create a separate clean checkout at commit `50aa28cb50da47ae2e97dbc1d1a4795eb05a3502`, which requests the D3D11 debug layer and therefore requires Windows Graphics Tools. Copy the example configuration to `framework-replacement-config.json`, set `PSAccelRepoPath` to that checkout and `OutputRoot` to a new output directory, and put Git on PATH. The example configuration requires an NVIDIA GPU. Start with `ValidateOnly`; the complete capture is a substantial memory/time workload.

```powershell
Set-Location ./benchmark/official
.\Invoke-FrameworkReplacementOfficialRun.ps1 -Mode ValidateOnly -ConfigPath .\framework-replacement-config.json
.\Invoke-FrameworkReplacementOfficialRun.ps1 -Mode SmokeTest -ConfigPath .\framework-replacement-config.json
.\Invoke-FrameworkReplacementOfficialRun.ps1 -Mode FinalOfficial -ConfigPath .\framework-replacement-config.json
.\Invoke-FrameworkReplacementOfficialRun.ps1 -Mode AnalyzeOnly -ConfigPath .\framework-replacement-config.json -RunRoot <completed-run-root>
.\Invoke-FrameworkReplacementOfficialRun.ps1 -Mode ArchiveOnly -ConfigPath .\framework-replacement-config.json -RunRoot <completed-run-root>
```

For the full capture, use a detached scheduled-task harness so remoting does not become part of the benchmark workload.

Generated artifacts can include local paths and hardware metadata. They are private run output until reviewed, and are not automatically part of this repository. The root `.gitignore` excludes `benchmark-output/` for a local output location. The published historical results live under `research/` and must remain unchanged.

## Official Workload Matrix

The primary framework workloads use deterministic PSCustomObject records with the repository-style shape:

- `Value = 1..N`
- `Score = (Value * 1.5) % 100`
- `Offset = (Value + 10) % 50`

Predeclared scenarios:

1. `DesktopStyle_OneProperty_TopFivePercent`
   - `Value -gt floor(N * 0.95)`
   - Low selectivity, one property

2. `DesktopStyle_OffsetScore_LowSelectivity`
   - `Offset -ne 3 -and Score -le 3`
   - Low selectivity, multi-clause

3. `DesktopStyle_ValueOffset_MediumSelectivity`
   - `Value -le floor(N * 0.58) -and Offset -gt 20`
   - Medium selectivity, multi-property

4. `DesktopStyle_ScoreOffsetValue_HighSelectivity`
   - `Offset -le 7 -or Score -gt 19 -or Value -le floor(N * 0.15)`
   - High selectivity, multi-property

Primary framework dataset tiers:

- 100,000
- 1,000,000

The 10,000,000-record PSCustomObject tier is predeclared as a memory-safety skip for this fresh run. The preserved aborted attempt `FrameworkReplacementOfficial-20260610T134355` showed that the first native `Where-Object` PSCustomObject 10M warmup exceeded the safe memory/time envelope under high private memory pressure. Those skipped tiers are written to `framework_replacement_skipped_scenarios.json` and are not performance results.

To keep the approved 10,000,000-record tier represented without optimizing the native baseline, the matrix also includes a boundary workload using a SyntheticRecord-style class object with the same `Value`, `Score`, and `Offset` properties:

1. `ClassBoundary_OneProperty_TopFivePercent`
   - `Value -gt floor(N * 0.95)`
   - Low selectivity, one property
   - Dataset tiers: 100,000; 1,000,000; 10,000,000

This boundary workload is official boundary-condition evidence, not an optimized CPU baseline. It shows how the framework behaves when native `Where-Object` has cheaper property access than PSCustomObject.

Default trials:

- 5 per method per scenario/tier

Expected official observations:

- Primary PSCustomObject: 4 scenarios x 2 tiers x 2 methods x 5 trials = 80 observations
- Boundary class: 1 scenario x 3 tiers x 2 methods x 5 trials = 30 observations
- Total planned official observations = 110 observations

Warmups are run but excluded from official observations.

## Integrity Rules

- Do not overwrite prior framework final artifacts.
- Do not mix prior aborted, diagnostic, VM, or superseded runs into this dataset.
- Do not rerun merely because results are unfavorable.
- If a technical failure occurs, preserve the failed run folder and archive it as aborted.
- Do not patch PSAccel during the official run.
- Refuse the run if the PSAccel repository is dirty unless explicitly allowed and documented.

## Outputs

Fresh official outputs are written to:

```text
C:\PSAccelExample\PSAccel_Dissertation_Results\FrameworkReplacementOfficial\FrameworkReplacementOfficial-<timestamp>
```

Key files:

- `framework_replacement_observations.csv`
- `framework_replacement_observations.json`
- `framework_replacement_summary.csv`
- `framework_replacement_comparison.csv`
- `framework_replacement_report.md`
- `framework_replacement_config.resolved.json`
- `framework_replacement_run_plan.csv`
- `framework_replacement_skipped_scenarios.json`
- `framework_replacement_validation.json`
- `framework_replacement_status.json`
- `artifact_manifest.json`
- `sha256sums.txt`
- final ZIP archive
