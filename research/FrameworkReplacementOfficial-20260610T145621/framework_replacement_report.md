# Framework Replacement Official Report

This run evaluates PSAccel as a framework replacement for native PowerShell Where-Object. The CPU condition is the native baseline and is not optimized beyond out-of-box Where-Object.

- Official comparisons: 11
- Comparisons where PSAccel mean was lower: 11
- Primary framework comparisons where PSAccel mean was lower: 8 of 8
- Boundary comparisons where PSAccel mean was lower: 3 of 3

| Workload group | Scenario | Dataset mode | Size | CPU mean ms | PSAccel mean ms | Reduction % | Speedup | PSAccel lower mean |
|---|---|---|---:|---:|---:|---:|---:|---|
| PrimaryFrameworkWorkloads | DesktopStyle_ValueOffset_MediumSelectivity | RepositoryStylePSCustomObject_ValueScoreOffset | 100000 | 1756.888 | 1269.311 | 27.752 | 1.3841 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_ScoreOffsetValue_HighSelectivity | RepositoryStylePSCustomObject_ValueScoreOffset | 100000 | 1796.621 | 1345.262 | 25.123 | 1.3355 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_OneProperty_TopFivePercent | RepositoryStylePSCustomObject_ValueScoreOffset | 100000 | 1710.698 | 1231.312 | 28.023 | 1.3893 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_OffsetScore_LowSelectivity | RepositoryStylePSCustomObject_ValueScoreOffset | 100000 | 1727.734 | 1273.093 | 26.314 | 1.3571 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_ValueOffset_MediumSelectivity | RepositoryStylePSCustomObject_ValueScoreOffset | 1000000 | 48819.37 | 24359.8 | 50.102 | 2.0041 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_ScoreOffsetValue_HighSelectivity | RepositoryStylePSCustomObject_ValueScoreOffset | 1000000 | 49699.264 | 25317.706 | 49.058 | 1.963 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_OneProperty_TopFivePercent | RepositoryStylePSCustomObject_ValueScoreOffset | 1000000 | 48221.482 | 23975.85 | 50.28 | 2.0113 | True |
| PrimaryFrameworkWorkloads | DesktopStyle_OffsetScore_LowSelectivity | RepositoryStylePSCustomObject_ValueScoreOffset | 1000000 | 48632.608 | 24689.547 | 49.233 | 1.9698 | True |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | RepositoryStyleSyntheticRecordClass_ValueScoreOffset | 100000 | 1198.332 | 833.235 | 30.467 | 1.4382 | True |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | RepositoryStyleSyntheticRecordClass_ValueScoreOffset | 1000000 | 12452.08 | 8769.31 | 29.576 | 1.42 | True |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | RepositoryStyleSyntheticRecordClass_ValueScoreOffset | 10000000 | 125646.597 | 90284.512 | 28.144 | 1.3917 | True |

## Framework Interpretation

PSAccel's CPU-side parsing, property projection, GPU staging, dispatch, readback, and result return are included in the measured PSAccel framework condition. Results should be phrased as PSAccel reducing execution time compared with native Where-Object for the specified workload.
