# Current 0.2.0 benchmark

This benchmark compares complete filtering calls over the same deterministic `PSCustomObject` arrays. It measures the current implementation, separately from the June 2026 study of 0.1.1. The historical study's files and measurements are unchanged.

## Reproduce

Use a fresh 64-bit Windows PowerShell 5.1 process on a Direct3D 11 machine:

```powershell
.\benchmark\current\Run-CurrentBenchmark.ps1
```

The default run generates 10,000, 100,000 and 500,000 rows. For each of two predicates, it runs four methods with two warmups and eight measured repetitions: **48 warmup and 192 measured observations**. Every result is checked for exact count, original-object identity and order outside the timed region. The script writes to a new timestamped results directory and refuses to overwrite an existing observation file. Sizes above 500,000 are rejected to keep this demonstration bounded.

A shorter harness check uses `-Sizes 1000 -WarmupRuns 1 -Repetitions 4`. An explicit `-OutputDirectory` selects another empty output directory. The optional D3D debug layer must be disabled. Avoid simultaneous builds, media processing and other heavy workloads.

After capture, use Python 3.8 or newer (standard library only):

```sh
python benchmark/current/summarize.py path/to/results
python benchmark/current/summarize.py path/to/results --verify-only
```

With no directory argument, the verifier checks the committed October 18 UTC capture. It checks raw-data SHA256, source hashes normalized to UTF-8/LF without BOM, trial coverage and ordering, independent mathematical result fixtures, and recomputed descriptive summaries. Source changes require an explicit decision about which implementation the recorded evidence describes; do not relabel old measurements as new ones.

## Workloads and timing boundary

Every row has an integer `Id` and three integer sensor-like fields:

```text
Value  = (Id * 37) modulo 1000
Group  = (Id * 13) modulo 17
Offset = (Id * 19) modulo 23
```

Values are exactly representable in single precision. This exercise does not evaluate rounding-sensitive inputs. The predicates are:

```powershell
{ $_.Value -ge 900 }
{ ($_.Value -ge 500 -and $_.Group -lt 4) -or $_.Offset -eq 0 }
```

| Method | Timed operation |
| --- | --- |
| `WhereObject` | PowerShell pipeline through native `Where-Object`, collected into an array |
| `PSAccelPipeline` | The same input pipeline through `PSA_Where-Object`, collected into an array |
| `PSAccelInputData` | `PSA_Where-Object -InputData` with the existing array, collected into an array |
| `CSharpLoop` | Specialized compiled, single-thread C# loop over the same `PSObject` properties, returning an array of original objects |

The compiled CPU baseline is deliberately specialized to these two predicates and the known valid integer schema. It uses direct property reads and Boolean short-circuiting; it has no preprojected numeric buffer. It does not provide the general validation, predicate translation or numeric-type handling of PSAccel. Its purpose is to show what avoiding PowerShell per-row predicate execution can achieve without a GPU.

PSAccel timings include predicate validation and translation, object-to-float projection, shader compilation, buffer allocation, dispatch, synchronization, readback and result materialization. The pipeline variant also includes accumulation of incoming objects. Input-array construction, module/C# compilation, warmups, correctness verification and hashing are excluded. The retained D3D device is warm; this is not a cold-start benchmark or a GPU-kernel-only measurement.

Each case uses a seeded method permutation, rotated every round; each method appears in each position twice during its eight measured repetitions. Natural garbage collections remain inside timings and their generation counts are recorded. Garbage collection is explicitly requested once before each case's warmups. Dataset sizes and predicates run in fixed order. No outliers are removed, and no confidence interval or significance claim is inferred from eight repeated observations on one host.

## Results from the October 18 UTC capture

Median complete-call elapsed time in milliseconds, eight measured repetitions per cell:

| Predicate | Rows | `WhereObject` | `PSAccelPipeline` | `PSAccelInputData` | `CSharpLoop` |
| --- | ---: | ---: | ---: | ---: | ---: |
| SingleProperty | 10,000 | 69.51 | 37.96 | 13.52 | **1.46** |
| SingleProperty | 100,000 | 1,169.76 | 455.96 | 90.64 | **17.85** |
| SingleProperty | 500,000 | 11,637.87 | 3,147.42 | 471.23 | **102.04** |
| ThreeProperty | 10,000 | 102.30 | 63.83 | 26.72 | **6.07** |
| ThreeProperty | 100,000 | 1,239.67 | 518.48 | 135.73 | **42.27** |
| ThreeProperty | 500,000 | 9,843.33 | 2,828.16 | 606.97 | **170.27** |

The pipeline-to-pipeline native/PSAccel median-time ratios range from **1.60 to 3.70**. The `-InputData` entry point avoids per-input-object PowerShell pipeline accumulation; its corresponding ratios against native `Where-Object` range from **3.83 to 24.70**. These entry points answer different API-cost questions and should be labeled separately.

The specialized CPU loop is fastest in every case. `PSAccelInputData` takes **3.21–9.25 times as long** and `PSAccelPipeline` takes **10.52–30.85 times as long**. Thus, a native PowerShell baseline alone would leave out an important alternative. For these predicates and known-valid inputs, direct compiled CPU evaluation avoids both PowerShell predicate dispatch and GPU projection/transfer/dispatch work. This result does not measure a feature-equivalent general CPU query framework.

Variability remains visible in the raw observations and quartiles/ranges in `summary.csv`. For example, the 100K three-property PSAccel pipeline spans 431.76–954.47 ms, with a 518.48 ms median; the compiled loop spans 38.07–102.68 ms, with a 42.27 ms median. All those trials are retained. Fixed case order, natural GC, caches and uncontrolled power/thermal conditions limit extrapolation. Further performance work should profile the full call path and evaluate representative workloads and additional hardware.

## Capture and evidence

The committed capture is under [`results/2026-10-18-integrated-gpu`](results/2026-10-18-integrated-gpu/):

- `environment.json`: runtime/hardware details, source hashes and observation checksum; neutral host label and no machine/user identifiers.
- `observations.csv`: every warmup and measured invocation, elapsed time, GC deltas, exact-result marker and selected-ID SHA256.
- `summary.csv`: median, mean, quartiles, range and sample standard deviation for each measured case/method.
- `ratios.csv`: ratios of medians, with numerator/denominator named explicitly.
- `run_notes.json`: coordinated quiet-window conditions, uncontrolled factors and source revision.

The selected-ID digest hashes UTF-8 decimal IDs, one per line including the final newline. The Python verifier independently calculates the expected IDs from the formulas above. Identity verification during capture also ensures that methods return the original input objects, rather than merely equivalent values.

The runtime source is the published 0.2.0 revision [`93fafed`](https://github.com/Derek-Poe/PSAccel/commit/93fafed2ef4f3aa5e17c75cae7b08aef9c6fdc57); source hashes in the capture are authoritative. Capture used an Intel Iris Xe integrated GPU and Core i7-1185G7, Windows 11 and Windows PowerShell 5.1. Other agent-driven builds, WSL media checks and heavy tests were paused during measurement. Ordinary desktop services, power management and thermal behavior were not controlled. The CPU and integrated GPU share host resources.

The current capture uses different hardware, predicates, sizes and entry-point comparisons from the historical RTX 3080 study. Do not pool the datasets or interpret their difference as a version-to-version speedup. There is no discrete-GPU replication or production-workload coverage in this capture.
