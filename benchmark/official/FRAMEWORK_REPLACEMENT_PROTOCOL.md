# Framework Replacement Protocol

This protocol supersedes the earlier framework-final matrix for the next fresh official capture. Earlier artifacts remain archived and must not be deleted, overwritten, or relabeled.

## Methodological Position

PSAccel is evaluated as a PowerShell-facing framework, not as an isolated GPU interop layer. Therefore, CPU-side parsing, projection, staging, GPU dispatch, readback, and result handling are part of the measured PSAccel condition.

The official CPU baseline is native out-of-box PowerShell `Where-Object`. The baseline is not replaced with optimized loops, LINQ, typed arrays, compiled delegates, or custom CPU filtering helpers.

## Official Conditions

- Native: `$data | Where-Object { <predicate> }`
- PSAccel: `$data | PSA_Where-Object { <same predicate> }`

## Dataset

Primary framework workloads use synthetic repository-style PSCustomObject records:

- `Value = 1..N`
- `Score = (Value * 1.5) % 100`
- `Offset = (Value + 10) % 50`

Boundary workloads use a SyntheticRecord-style class object with the same properties. This is not an optimized CPU baseline; it is boundary-condition evidence for the required 10,000,000-record tier when PSCustomObject 10M is not memory-safe on the controlled machine.

No human subjects, PHI, CTU institutional data, or production organizational data are used.

## Dataset Tiers

- Primary PSCustomObject tiers: 100,000 and 1,000,000
- Predeclared PSCustomObject skip: 10,000,000 due memory-safety evidence from the preserved aborted `FrameworkReplacementOfficial-20260610T134355` attempt
- Boundary class tiers: 100,000; 1,000,000; and 10,000,000

## Trials

- 5 repeated trials per method per scenario/tier
- Warmups are required and excluded from official observations
- Method order is randomized with a fixed seed before observations begin

## Primary Framework Scenarios

1. `DesktopStyle_OneProperty_TopFivePercent`
   - `Value -gt floor(N * 0.95)`

2. `DesktopStyle_OffsetScore_LowSelectivity`
   - `Offset -ne 3 and Score -le 3`

3. `DesktopStyle_ValueOffset_MediumSelectivity`
   - `Value -le floor(N * 0.58) and Offset -gt 20`

4. `DesktopStyle_ScoreOffsetValue_HighSelectivity`
   - `Offset -le 7 or Score -gt 19 or Value -le floor(N * 0.15)`

## Boundary Scenario

1. `ClassBoundary_OneProperty_TopFivePercent`
   - `Value -gt floor(N * 0.95)`
   - Runs at 100,000; 1,000,000; and 10,000,000 records

Expected official observations:

- Primary PSCustomObject: 4 scenarios x 2 tiers x 2 methods x 5 trials = 80
- Boundary class: 1 scenario x 3 tiers x 2 methods x 5 trials = 30
- Total planned official observations = 110

## Integrity

Do not rerun merely because results are unfavorable. If a technical failure occurs, preserve and label the failed artifacts separately before starting a replacement run.
