# APA-Style Statistical Comparison Table

Each row compares native `Where-Object` with `PSA_Where-Object` for one scenario/tier. Positive reduction and Cohen's d values indicate lower PSAccel elapsed time.

| Group | Scenario | N | CPU M ms | PSAccel M ms | Reduction % | Speedup | 95% CI reduction ms | CPU Shapiro p | PSAccel Shapiro p | Levene p | Welch t | Mann-Whitney | Cohen's d |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | 100000 | 1198.332 | 833.235 | 30.467 | 1.4382 | [296.672, 433.523] | 0.069 | 0.281 | 0.620 | 12.311, df=7.98, p=< .001 | U=25.000, p=0.008 | 7.786 |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | 1000000 | 12452.080 | 8769.310 | 29.576 | 1.4200 | [3556.998, 3808.541] | 0.343 | 0.148 | 0.552 | 69.824, df=6.72, p=< .001 | U=25.000, p=0.008 | 44.161 |
| BoundaryWorkloads | ClassBoundary_OneProperty_TopFivePercent | 10000000 | 125646.597 | 90284.512 | 28.144 | 1.3917 | [34038.189, 36685.979] | 0.644 | 0.903 | 0.025 | 72.684, df=4.22, p=< .001 | U=25.000, p=0.008 | 45.969 |
| PrimaryFrameworkWorkloads | DesktopStyle_OffsetScore_LowSelectivity | 100000 | 1727.734 | 1273.093 | 26.314 | 1.3571 | [440.746, 468.537] | 0.017 | 0.658 | 0.642 | 81.797, df=5.52, p=< .001 | U=25.000, p=0.008 | 51.733 |
| PrimaryFrameworkWorkloads | DesktopStyle_OffsetScore_LowSelectivity | 1000000 | 48632.608 | 24689.547 | 49.233 | 1.9698 | [23710.719, 24175.404] | 0.467 | 0.200 | 0.064 | 278.541, df=4.29, p=< .001 | U=25.000, p=0.008 | 176.165 |
| PrimaryFrameworkWorkloads | DesktopStyle_OneProperty_TopFivePercent | 100000 | 1710.698 | 1231.312 | 28.023 | 1.3893 | [453.181, 505.590] | 0.248 | 0.517 | 0.371 | 46.771, df=5.09, p=< .001 | U=25.000, p=0.008 | 29.580 |
| PrimaryFrameworkWorkloads | DesktopStyle_OneProperty_TopFivePercent | 1000000 | 48221.482 | 23975.850 | 50.280 | 2.0113 | [24104.979, 24386.286] | 0.560 | 0.609 | 0.591 | 417.742, df=6.25, p=< .001 | U=25.000, p=0.008 | 264.203 |
| PrimaryFrameworkWorkloads | DesktopStyle_ScoreOffsetValue_HighSelectivity | 100000 | 1796.621 | 1345.262 | 25.123 | 1.3355 | [445.150, 457.568] | 0.736 | 0.851 | 0.921 | 169.133, df=7.61, p=< .001 | U=25.000, p=0.008 | 106.969 |
| PrimaryFrameworkWorkloads | DesktopStyle_ScoreOffsetValue_HighSelectivity | 1000000 | 49699.264 | 25317.706 | 49.058 | 1.9630 | [24245.650, 24517.466] | 0.405 | 0.430 | 0.040 | 475.129, df=4.55, p=< .001 | U=25.000, p=0.008 | 300.498 |
| PrimaryFrameworkWorkloads | DesktopStyle_ValueOffset_MediumSelectivity | 100000 | 1756.888 | 1269.311 | 27.752 | 1.3841 | [463.492, 511.664] | 0.391 | 0.293 | 0.936 | 47.149, df=7.57, p=< .001 | U=25.000, p=0.008 | 29.820 |
| PrimaryFrameworkWorkloads | DesktopStyle_ValueOffset_MediumSelectivity | 1000000 | 48819.370 | 24359.800 | 50.102 | 2.0041 | [24230.536, 24688.606] | 0.679 | 0.660 | 0.104 | 281.205, df=4.63, p=< .001 | U=25.000, p=0.008 | 177.850 |