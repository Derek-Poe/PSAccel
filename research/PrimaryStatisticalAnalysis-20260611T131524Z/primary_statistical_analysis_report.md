# Primary Statistical Analysis Report

- Generated UTC: `2026-06-11T13:15:24.275529+00:00`
- Primary dataset run root: `C:\PSAccelExample\Dissertation_Research\metadata\framework-replacement-official-20260610T145621\FrameworkReplacementOfficial-20260610T145621`
- Observation source: `C:\PSAccelExample\Dissertation_Research\metadata\framework-replacement-official-20260610T145621\FrameworkReplacementOfficial-20260610T145621\framework_replacement_observations.csv`
- Official baseline: native PowerShell `Where-Object`
- PSAccel condition: `PSA_Where-Object`
- Unit of analysis: scenario/tier comparison with 5 trials per method
- Tests: Shapiro-Wilk, Levene/Brown-Forsythe, Welch t-test, Mann-Whitney U backup, Cohen's d, and 95% confidence intervals

## Integrity Boundary

This analysis treats `FrameworkReplacementOfficial-20260610T145621` as the primary analysis dataset. Prior VM, baseline, expanded, aborted, and superseded runs are preserved separately and are not pooled into these results.
Predeclared skipped PSCustomObject 10M tiers are documented in `C:\PSAccelExample\Dissertation_Research\metadata\framework-replacement-official-20260610T145621\FrameworkReplacementOfficial-20260610T145621\framework_replacement_skipped_scenarios.json` and are not performance observations.

## Summary

- Scenario/tier comparisons: `11`
- Comparisons where PSAccel mean was lower: `11 of 11`
- Primary framework comparisons where PSAccel mean was lower: `8 of 8`
- Boundary comparisons where PSAccel mean was lower: `3 of 3`

## Statistical Results

| Group | Scenario | Dataset size | CPU mean ms | PSAccel mean ms | Reduction % | Speedup | 95% CI reduction ms | Welch p | Mann-Whitney p | Cohen's d |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | 100000 | 1198.332 | 833.235 | 30.467 | 1.4382 | [296.672, 433.523] | < .001 | 0.008 | 7.786 |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | 1000000 | 12452.080 | 8769.310 | 29.576 | 1.4200 | [3556.998, 3808.541] | < .001 | 0.008 | 44.161 |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | 10000000 | 125646.597 | 90284.512 | 28.144 | 1.3917 | [34038.189, 36685.979] | < .001 | 0.008 | 45.969 |
| PrimaryFrameworkWorkloads | DesktopStyle_OffsetScore_LowSelectivity | 100000 | 1727.734 | 1273.093 | 26.314 | 1.3571 | [440.746, 468.537] | < .001 | 0.008 | 51.733 |
| PrimaryFrameworkWorkloads | DesktopStyle_OffsetScore_LowSelectivity | 1000000 | 48632.608 | 24689.547 | 49.233 | 1.9698 | [23710.719, 24175.404] | < .001 | 0.008 | 176.165 |
| PrimaryFrameworkWorkloads | DesktopStyle_OneProperty_TopFivePercent | 100000 | 1710.698 | 1231.312 | 28.023 | 1.3893 | [453.181, 505.590] | < .001 | 0.008 | 29.580 |
| PrimaryFrameworkWorkloads | DesktopStyle_OneProperty_TopFivePercent | 1000000 | 48221.482 | 23975.850 | 50.280 | 2.0113 | [24104.979, 24386.286] | < .001 | 0.008 | 264.203 |
| PrimaryFrameworkWorkloads | DesktopStyle_ScoreOffsetValue_HighSelectivity | 100000 | 1796.621 | 1345.262 | 25.123 | 1.3355 | [445.150, 457.568] | < .001 | 0.008 | 106.969 |
| PrimaryFrameworkWorkloads | DesktopStyle_ScoreOffsetValue_HighSelectivity | 1000000 | 49699.264 | 25317.706 | 49.058 | 1.9630 | [24245.650, 24517.466] | < .001 | 0.008 | 300.498 |
| PrimaryFrameworkWorkloads | DesktopStyle_ValueOffset_MediumSelectivity | 100000 | 1756.888 | 1269.311 | 27.752 | 1.3841 | [463.492, 511.664] | < .001 | 0.008 | 29.820 |
| PrimaryFrameworkWorkloads | DesktopStyle_ValueOffset_MediumSelectivity | 1000000 | 48819.370 | 24359.800 | 50.102 | 2.0041 | [24230.536, 24688.606] | < .001 | 0.008 | 177.850 |

## Interpretation Guardrails

- These tests compare PSAccel against native `Where-Object`, not against optimized CPU implementations.
- Shapiro-Wilk results should be interpreted cautiously because each method has `n=5` trials per scenario/tier.
- Welch t-tests are reported as the robust default for unequal variance assumptions.
- Mann-Whitney U tests are provided as a nonparametric backup, not as a replacement for reporting practical effect size.
- Positive Cohen's d values indicate that CPU `Where-Object` had larger elapsed times than PSAccel.
- Statistical significance and practical speedup should be discussed separately.
