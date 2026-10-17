# PSAccel

PSAccel filters PowerShell objects with Direct3D 11 compute shaders. It translates a bounded numeric predicate into HLSL, projects the referenced properties into a structured buffer, runs the predicate on the GPU, and uses the returned mask to select the original objects in order.

This project combines PowerShell language integration, C# native interop, GPU buffer management, and a controlled study of end-to-end framework performance. It is a numeric-filtering prototype, with a deliberately narrower contract than `Where-Object`.

## Try it

Use 64-bit Windows PowerShell 5.1 on Windows with a Direct3D 11 compute-capable GPU and driver. The module compiles its bundled C# source at import; no external managed library is required. PowerShell 7 is not currently a validated target.

```powershell
git clone https://github.com/Derek-Poe/PSAccel.git
Import-Module ./PSAccel/PSAccel.psd1
$rows = @(1..1024 | ForEach-Object {
    [pscustomobject]@{ Id = $_; Score = $_ % 100 }
})
$rows | PSA_Where-Object { $_.Score -ge 95 }
```

The aliases `?G` and `PSA_?` are also available. Pass an existing array through `-InputData $rows` to avoid pipeline accumulation. Imports work from any working directory. Restart PowerShell after changing the bundled C# source: an already loaded .NET type cannot be replaced by reimporting the module.

## How it works

```mermaid
flowchart LR
    A[PowerShell objects and predicate] --> B[Validate syntax and generate HLSL]
    B --> C[Project numeric properties to float rows]
    C --> D[D3D11 structured input buffer]
    D --> E[Compute shader: 256 threads per group]
    E --> F[One uint result per row]
    F --> G[Staging buffer and CPU readback]
    G --> H[Original matching objects in original order]
```

`PSAccel.psm1` handles PowerShell binding and shader generation. `PSAccel.cs` uses P/Invoke and COM vtable delegates to create buffers and views, compile HLSL, dispatch work, and read the result mask. Per-call resources are unbound and released even if shader compilation or execution fails. One device and immediate context are retained for the process; concurrent calls into that context are not supported.

## Predicate and numeric contract

- Numeric properties with simple names, such as `$_.Score`.
- Comparisons `-gt`, `-lt`, `-ge`, `-le`, `-eq`, and `-ne`, joined by `-and`, `-or`, and parentheses.
- Numeric constants and numeric variables visible to the calling PowerShell scope.
- Missing, null, string, NaN, and infinite property values are rejected. Method calls, commands, string predicates, statement blocks, and Boolean/numeric coercion are rejected.

Properties and variable thresholds are projected to IEEE 754 single precision. Large integers and closely spaced decimal values can therefore compare differently from native PowerShell: integers above 16,777,216 are not all exactly representable. This is not a general semantic replacement for `Where-Object`. Validate the numeric range of a workload before using it. Inputs are accumulated in memory; the GPU path is not streaming. One dispatch supports up to 16,776,960 rows, subject to available memory and device limits.

## Research results

The June 2026 study measured source commit [`50aa28c`](https://github.com/Derek-Poe/PSAccel/commit/50aa28cb50da47ae2e97dbc1d1a4795eb05a3502), using Windows PowerShell 5.1, an RTX 3080, and a Ryzen 7 3700X. It compared the whole PSAccel framework path against native `Where-Object`, including projection, transfer, dispatch, readback, and output materialization.

| Completed workload | Dataset sizes | Observations | Mean native / PSAccel time ratio |
| --- | --- | --- | --- |
| Four PSCustomObject numeric predicates | 100K and 1M | 80 | 1.34–1.39x at 100K; 1.96–2.01x at 1M |
| One class-based boundary predicate | 100K, 1M and 10M | 30 | 1.39–1.44x |

Each of the 11 scenario/size comparisons has five trials per method. All 110 observations matched the expected **result count**; the study did not establish element-by-element equivalence. The four 10M PSCustomObject conditions were skipped for memory safety. No optimized CPU loop or LINQ baseline was included.

The [research package](research/README.md) includes the observations, warmups, methodology, analysis source, and provenance hashes. Machine labels and local paths have been replaced in an explicitly identified public derivative; measurements are unchanged.

**These timings describe the measured 0.1.1 source, not the current 0.2.0 maintenance version.** Current changes include AST-preserving predicate translation, structured-buffer layout and output sizing, resource cleanup, stricter input validation, portable imports, and an optional debug layer. No new performance claim is made for them. Older exploratory plots under `benchmark/Filtering` remain historical artifacts and should not be combined with the controlled study.

## Validation

```powershell
# Import, manifest, empty-input and unsupported-predicate checks; no GPU dispatch.
./tests/Test-PSAccel.ps1
# Exact output and object identity, multiple properties, partial thread groups,
# variables, locale handling, invalid data and recovery after shader failure.
./tests/Test-PSAccel.ps1 -Gpu
```

```sh
python tests/verify_research.py
```

The GPU suite has passed on Windows PowerShell 5.1 with Intel Iris Xe graphics. Hosted CI runs the non-GPU checks and research integrity checks. The original RTX 3080 study has not been rerun for this release. Set `PSACCEL_D3D_DEBUG=1` before the first dispatch to request the optional D3D11 debug layer; that mode requires Windows Graphics Tools.

The [small example](examples/QuickStart.ps1) is suitable for a quick demonstration. The [research harness](benchmark/official/README.md) is a separate, potentially long-running capture workflow pinned to the measured source.

## License

MIT, copyright Derek Poe. See [LICENSE](LICENSE).
