# PSAccel research evidence

The primary capture is `FrameworkReplacementOfficial-20260610T145621`, completed on June 10, 2026. It measures source commit `50aa28cb50da47ae2e97dbc1d1a4795eb05a3502`, before the current maintenance changes. The dataset consists of 110 measured observations and 22 separate warmups, with five observations per method in each of 11 scenario/size comparisons.

The four primary PSCustomObject predicates were measured at 100K and 1M rows; their 10M conditions were predeclared memory-safety skips. One class-based boundary predicate also completed the 10M condition. The baseline is native PowerShell `Where-Object`, not an optimized CPU implementation. Result-count agreement is the historical correctness check; it does not prove identical selected records.

## Files and provenance

- The capture directory contains raw observation and warmup CSVs, the run plan, expected counts, summaries, comparisons, completion status, and skip records.
- `PrimaryStatisticalAnalysis-20260611T131524Z` contains the analysis program and stored descriptive/inferential tables and reports. Its Python source was recovered from the original analysis archive.
- [`provenance.json`](provenance.json) records the SHA256 of each original and its public derivative. Files marked unchanged retain their original bytes. Other files replace the host label or local research directory; no timing, trial, predicate, count, or analysis value was changed.

References to the original observation SHA256 inside historical analysis reports identify the original private capture. That checksum intentionally differs from the sanitized public CSV checksum. Use `public_sha256` in the manifest to verify the files in this repository. The original observations hash is `1de25d4dc2f246d6c4f28a1e08e33ee4eb014a9c4112bd31f39d458410e62591`.

The standalone integrity check recomputes means and ratios from the 110 rows, checks counts and trial coverage, and verifies all exported research hashes. The stored Welch tests report p < .001 for all 11 comparisons; the integrity check does not rerun those inferential tests.

## Recompute the analysis

The analysis program requires Python, NumPy and SciPy. In an isolated Python environment:

```sh
python -m pip install numpy scipy
python research/PrimaryStatisticalAnalysis-20260611T131524Z/Analyze-FrameworkReplacementPrimaryStats.py --run-root research/FrameworkReplacementOfficial-20260610T145621 --output-root analysis-output
```

It creates a new timestamped directory and refuses to overwrite an existing one. Newly computed report metadata and source hashes will refer to the sanitized dataset and your local paths; keep generated outputs out of commits until reviewed.

For a fresh hardware capture, see the [historical harness](../benchmark/official/README.md). Fresh capture results belong to a new run and must not overwrite or be pooled with this dataset.
