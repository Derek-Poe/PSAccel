#!/usr/bin/env python3
"""Primary statistical analysis for the PSAccel framework-replacement run.

This script treats FrameworkReplacementOfficial-20260610T145621 as the primary
analysis dataset and performs scenario/tier comparisons between native
PowerShell Where-Object and PSAccel PSA_Where-Object. Optimized CPU baselines
are intentionally absent because the dissertation evaluates PSAccel as a
PowerShell-facing framework replacement.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import numpy as np
from scipy import stats


CPU_METHOD = "CPUWhereObject"
PSACCEL_METHOD = "PSAccelWhereObject"


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def truthy(value: Any) -> bool:
    return str(value).strip().lower() in {"true", "1", "yes", "y"}


def safe_float(value: Any) -> float | None:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def finite_or_none(value: float | None) -> float | None:
    if value is None:
        return None
    if isinstance(value, (float, int)) and math.isfinite(float(value)):
        return float(value)
    return None


def rounded(value: float | None, digits: int = 6) -> float | None:
    value = finite_or_none(value)
    if value is None:
        return None
    return round(value, digits)


def significant(value: float | None, digits: int = 12) -> float | None:
    value = finite_or_none(value)
    if value is None:
        return None
    return float(f"{value:.{digits}g}")


def mean_ci(values: np.ndarray, alpha: float = 0.05) -> tuple[float | None, float | None]:
    n = len(values)
    if n < 2:
        return None, None
    sd = float(np.std(values, ddof=1))
    se = sd / math.sqrt(n)
    tcrit = float(stats.t.ppf(1.0 - alpha / 2.0, n - 1))
    mean = float(np.mean(values))
    return mean - tcrit * se, mean + tcrit * se


def descriptive(values: Iterable[float]) -> dict[str, Any]:
    arr = np.array(list(values), dtype=float)
    if len(arr) == 0:
        return {
            "n": 0,
            "mean_ms": None,
            "sd_ms": None,
            "median_ms": None,
            "min_ms": None,
            "max_ms": None,
            "q1_ms": None,
            "q3_ms": None,
            "iqr_ms": None,
            "ci95_mean_lower_ms": None,
            "ci95_mean_upper_ms": None,
        }
    ci_low, ci_high = mean_ci(arr)
    q1 = float(np.percentile(arr, 25))
    q3 = float(np.percentile(arr, 75))
    return {
        "n": int(len(arr)),
        "mean_ms": rounded(float(np.mean(arr)), 3),
        "sd_ms": rounded(float(np.std(arr, ddof=1)) if len(arr) > 1 else 0.0, 3),
        "median_ms": rounded(float(np.median(arr)), 3),
        "min_ms": rounded(float(np.min(arr)), 3),
        "max_ms": rounded(float(np.max(arr)), 3),
        "q1_ms": rounded(q1, 3),
        "q3_ms": rounded(q3, 3),
        "iqr_ms": rounded(q3 - q1, 3),
        "ci95_mean_lower_ms": rounded(ci_low, 3),
        "ci95_mean_upper_ms": rounded(ci_high, 3),
    }


def shapiro(values: np.ndarray) -> dict[str, Any]:
    if len(values) < 3:
        return {"statistic": None, "p_value": None, "note": "not measured; n < 3"}
    result = stats.shapiro(values)
    return {
        "statistic": rounded(float(result.statistic), 6),
        "p_value": significant(float(result.pvalue)),
        "note": "Shapiro-Wilk normality test; n=5 has low power.",
    }


def welch_df(a: np.ndarray, b: np.ndarray) -> float | None:
    n1 = len(a)
    n2 = len(b)
    if n1 < 2 or n2 < 2:
        return None
    s1 = float(np.var(a, ddof=1))
    s2 = float(np.var(b, ddof=1))
    term1 = s1 / n1
    term2 = s2 / n2
    numerator = (term1 + term2) ** 2
    denominator = (term1**2 / (n1 - 1)) + (term2**2 / (n2 - 1))
    if denominator == 0:
        return None
    return numerator / denominator


def difference_ci(a: np.ndarray, b: np.ndarray, alpha: float = 0.05) -> tuple[float | None, float | None, float | None]:
    df = welch_df(a, b)
    if df is None:
        return None, None, None
    sd_a = float(np.std(a, ddof=1))
    sd_b = float(np.std(b, ddof=1))
    se = math.sqrt((sd_a**2 / len(a)) + (sd_b**2 / len(b)))
    tcrit = float(stats.t.ppf(1.0 - alpha / 2.0, df))
    diff = float(np.mean(a) - np.mean(b))
    return diff - tcrit * se, diff + tcrit * se, df


def cohens_d(cpu: np.ndarray, psaccel: np.ndarray) -> float | None:
    n1 = len(cpu)
    n2 = len(psaccel)
    if n1 < 2 or n2 < 2:
        return None
    sd1 = float(np.std(cpu, ddof=1))
    sd2 = float(np.std(psaccel, ddof=1))
    pooled_num = ((n1 - 1) * sd1**2) + ((n2 - 1) * sd2**2)
    pooled_den = n1 + n2 - 2
    if pooled_den <= 0:
        return None
    pooled = math.sqrt(pooled_num / pooled_den)
    if pooled == 0:
        return None
    return (float(np.mean(cpu)) - float(np.mean(psaccel))) / pooled


def test_row(group_key: tuple[str, str, str, str, str, str], rows: list[dict[str, str]]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    workload_group, scenario_name, dataset_mode, dataset_size, predicate_name, selectivity = group_key
    cpu = np.array(
        [float(r["StopwatchElapsedMs"]) for r in rows if r["Method"] == CPU_METHOD],
        dtype=float,
    )
    psaccel = np.array(
        [float(r["StopwatchElapsedMs"]) for r in rows if r["Method"] == PSACCEL_METHOD],
        dtype=float,
    )
    if len(cpu) == 0 or len(psaccel) == 0:
        raise ValueError(f"Missing CPU or PSAccel rows for {group_key}")

    cpu_desc = descriptive(cpu)
    ps_desc = descriptive(psaccel)
    diff = float(np.mean(cpu) - np.mean(psaccel))
    percent_reduction = (diff / float(np.mean(cpu))) * 100.0 if float(np.mean(cpu)) else None
    speedup = float(np.mean(cpu) / np.mean(psaccel)) if float(np.mean(psaccel)) else None

    shapiro_cpu = shapiro(cpu)
    shapiro_ps = shapiro(psaccel)
    levene_result = stats.levene(cpu, psaccel, center="median")
    welch_result = stats.ttest_ind(cpu, psaccel, equal_var=False)
    mw_result = stats.mannwhitneyu(cpu, psaccel, alternative="two-sided", method="auto")
    ci_diff_low, ci_diff_high, df = difference_ci(cpu, psaccel)
    d = cohens_d(cpu, psaccel)

    assumptions_note = []
    if shapiro_cpu["p_value"] is not None and shapiro_cpu["p_value"] < 0.05:
        assumptions_note.append("CPU Shapiro-Wilk p < .05")
    if shapiro_ps["p_value"] is not None and shapiro_ps["p_value"] < 0.05:
        assumptions_note.append("PSAccel Shapiro-Wilk p < .05")
    if float(levene_result.pvalue) < 0.05:
        assumptions_note.append("Levene/Brown-Forsythe p < .05")
    if not assumptions_note:
        assumptions_note.append("No assumption flag at alpha=.05; interpret cautiously with n=5 per method.")

    comparison = {
        "WorkloadGroup": workload_group,
        "ScenarioName": scenario_name,
        "DatasetMode": dataset_mode,
        "DatasetSize": int(dataset_size),
        "PredicateName": predicate_name,
        "SelectivityLabel": selectivity,
        "CPU_N": int(len(cpu)),
        "PSAccel_N": int(len(psaccel)),
        "CPU_MeanMs": cpu_desc["mean_ms"],
        "CPU_SDMs": cpu_desc["sd_ms"],
        "CPU_CI95_Mean_LowerMs": cpu_desc["ci95_mean_lower_ms"],
        "CPU_CI95_Mean_UpperMs": cpu_desc["ci95_mean_upper_ms"],
        "PSAccel_MeanMs": ps_desc["mean_ms"],
        "PSAccel_SDMs": ps_desc["sd_ms"],
        "PSAccel_CI95_Mean_LowerMs": ps_desc["ci95_mean_lower_ms"],
        "PSAccel_CI95_Mean_UpperMs": ps_desc["ci95_mean_upper_ms"],
        "AbsoluteReductionMs": rounded(diff, 3),
        "CI95_Reduction_LowerMs": rounded(ci_diff_low, 3),
        "CI95_Reduction_UpperMs": rounded(ci_diff_high, 3),
        "PercentReduction": rounded(percent_reduction, 3),
        "SpeedupRatio": rounded(speedup, 4),
        "PSAccelMeanLower": bool(np.mean(psaccel) < np.mean(cpu)),
        "Shapiro_CPU_W": shapiro_cpu["statistic"],
        "Shapiro_CPU_p": shapiro_cpu["p_value"],
        "Shapiro_PSAccel_W": shapiro_ps["statistic"],
        "Shapiro_PSAccel_p": shapiro_ps["p_value"],
        "Levene_BrownForsythe_F": rounded(float(levene_result.statistic), 6),
        "Levene_BrownForsythe_p": significant(float(levene_result.pvalue)),
        "Welch_t": rounded(float(welch_result.statistic), 6),
        "Welch_df": rounded(df, 6),
        "Welch_p_two_sided": significant(float(welch_result.pvalue)),
        "MannWhitney_U": rounded(float(mw_result.statistic), 6),
        "MannWhitney_p_two_sided": significant(float(mw_result.pvalue)),
        "CohensD_CPUminusPSAccel": rounded(d, 6),
        "AssumptionNote": "; ".join(assumptions_note),
    }

    descriptives = []
    for method, desc, sh in [
        (CPU_METHOD, cpu_desc, shapiro_cpu),
        (PSACCEL_METHOD, ps_desc, shapiro_ps),
    ]:
        row = {
            "WorkloadGroup": workload_group,
            "ScenarioName": scenario_name,
            "DatasetMode": dataset_mode,
            "DatasetSize": int(dataset_size),
            "PredicateName": predicate_name,
            "SelectivityLabel": selectivity,
            "Method": method,
            **desc,
            "Shapiro_W": sh["statistic"],
            "Shapiro_p": sh["p_value"],
            "ShapiroNote": sh["note"],
        }
        descriptives.append(row)

    return comparison, descriptives


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fieldnames = list(rows[0].keys())
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=False), encoding="utf-8")


def markdown_table(headers: list[str], rows: list[list[Any]]) -> str:
    lines = []
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for row in rows:
        lines.append("| " + " | ".join("" if v is None else str(v) for v in row) + " |")
    return "\n".join(lines)


def fmt_p(value: Any) -> str:
    if value is None:
        return "not measured"
    value = float(value)
    if value < 0.001:
        return "< .001"
    return f"{value:.3f}"


def fmt_num(value: Any, digits: int = 3) -> str:
    if value is None:
        return "not measured"
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return str(value)


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def build_report(
    output_dir: Path,
    run_root: Path,
    observations_path: Path,
    comparisons: list[dict[str, Any]],
    descriptives: list[dict[str, Any]],
    skipped_path: Path | None,
) -> None:
    primary = [r for r in comparisons if r["WorkloadGroup"] == "PrimaryFrameworkWorkloads"]
    boundary = [r for r in comparisons if r["WorkloadGroup"] == "BoundaryWorkloads"]
    improved = [r for r in comparisons if r["PSAccelMeanLower"]]
    primary_improved = [r for r in primary if r["PSAccelMeanLower"]]
    boundary_improved = [r for r in boundary if r["PSAccelMeanLower"]]

    test_rows = []
    for r in comparisons:
        test_rows.append(
            [
                r["WorkloadGroup"],
                r["ScenarioName"],
                r["DatasetSize"],
                fmt_num(r["CPU_MeanMs"]),
                fmt_num(r["PSAccel_MeanMs"]),
                fmt_num(r["PercentReduction"]),
                fmt_num(r["SpeedupRatio"], 4),
                f"[{fmt_num(r['CI95_Reduction_LowerMs'])}, {fmt_num(r['CI95_Reduction_UpperMs'])}]",
                fmt_p(r["Shapiro_CPU_p"]),
                fmt_p(r["Shapiro_PSAccel_p"]),
                fmt_p(r["Levene_BrownForsythe_p"]),
                f"{fmt_num(r['Welch_t'])}, df={fmt_num(r['Welch_df'], 2)}, p={fmt_p(r['Welch_p_two_sided'])}",
                f"U={fmt_num(r['MannWhitney_U'])}, p={fmt_p(r['MannWhitney_p_two_sided'])}",
                fmt_num(r["CohensD_CPUminusPSAccel"]),
            ]
        )

    test_md = "# APA-Style Statistical Comparison Table\n\n"
    test_md += "Each row compares native `Where-Object` with `PSA_Where-Object` for one scenario/tier. Positive reduction and Cohen's d values indicate lower PSAccel elapsed time.\n\n"
    test_md += markdown_table(
        [
            "Group",
            "Scenario",
            "N",
            "CPU M ms",
            "PSAccel M ms",
            "Reduction %",
            "Speedup",
            "95% CI reduction ms",
            "CPU Shapiro p",
            "PSAccel Shapiro p",
            "Levene p",
            "Welch t",
            "Mann-Whitney",
            "Cohen's d",
        ],
        test_rows,
    )
    (output_dir / "apa_statistical_tests.md").write_text(test_md, encoding="utf-8")

    desc_rows = []
    for r in descriptives:
        desc_rows.append(
            [
                r["WorkloadGroup"],
                r["ScenarioName"],
                r["DatasetSize"],
                r["Method"],
                r["n"],
                fmt_num(r["mean_ms"]),
                fmt_num(r["sd_ms"]),
                fmt_num(r["median_ms"]),
                fmt_num(r["iqr_ms"]),
                f"[{fmt_num(r['ci95_mean_lower_ms'])}, {fmt_num(r['ci95_mean_upper_ms'])}]",
                fmt_p(r["Shapiro_p"]),
            ]
        )
    desc_md = "# APA-Style Descriptive Table\n\n"
    desc_md += markdown_table(
        [
            "Group",
            "Scenario",
            "N",
            "Method",
            "n",
            "M ms",
            "SD ms",
            "Median ms",
            "IQR ms",
            "95% CI mean ms",
            "Shapiro p",
        ],
        desc_rows,
    )
    (output_dir / "apa_descriptive_table.md").write_text(desc_md, encoding="utf-8")

    report = []
    report.append("# Primary Statistical Analysis Report")
    report.append("")
    report.append(f"- Generated UTC: `{datetime.now(timezone.utc).isoformat()}`")
    report.append(f"- Primary dataset run root: `{run_root}`")
    report.append(f"- Observation source: `{observations_path}`")
    report.append("- Official baseline: native PowerShell `Where-Object`")
    report.append("- PSAccel condition: `PSA_Where-Object`")
    report.append("- Unit of analysis: scenario/tier comparison with 5 trials per method")
    report.append("- Tests: Shapiro-Wilk, Levene/Brown-Forsythe, Welch t-test, Mann-Whitney U backup, Cohen's d, and 95% confidence intervals")
    report.append("")
    report.append("## Integrity Boundary")
    report.append("")
    report.append("This analysis treats `FrameworkReplacementOfficial-20260610T145621` as the primary analysis dataset. Prior VM, baseline, expanded, aborted, and superseded runs are preserved separately and are not pooled into these results.")
    if skipped_path:
        report.append(f"Predeclared skipped PSCustomObject 10M tiers are documented in `{skipped_path}` and are not performance observations.")
    report.append("")
    report.append("## Summary")
    report.append("")
    report.append(f"- Scenario/tier comparisons: `{len(comparisons)}`")
    report.append(f"- Comparisons where PSAccel mean was lower: `{len(improved)} of {len(comparisons)}`")
    report.append(f"- Primary framework comparisons where PSAccel mean was lower: `{len(primary_improved)} of {len(primary)}`")
    report.append(f"- Boundary comparisons where PSAccel mean was lower: `{len(boundary_improved)} of {len(boundary)}`")
    report.append("")
    report.append("## Statistical Results")
    report.append("")
    report.append(markdown_table(
        ["Group", "Scenario", "Dataset size", "CPU mean ms", "PSAccel mean ms", "Reduction %", "Speedup", "95% CI reduction ms", "Welch p", "Mann-Whitney p", "Cohen's d"],
        [
            [
                r["WorkloadGroup"],
                r["ScenarioName"],
                r["DatasetSize"],
                fmt_num(r["CPU_MeanMs"]),
                fmt_num(r["PSAccel_MeanMs"]),
                fmt_num(r["PercentReduction"]),
                fmt_num(r["SpeedupRatio"], 4),
                f"[{fmt_num(r['CI95_Reduction_LowerMs'])}, {fmt_num(r['CI95_Reduction_UpperMs'])}]",
                fmt_p(r["Welch_p_two_sided"]),
                fmt_p(r["MannWhitney_p_two_sided"]),
                fmt_num(r["CohensD_CPUminusPSAccel"]),
            ]
            for r in comparisons
        ],
    ))
    report.append("")
    report.append("## Interpretation Guardrails")
    report.append("")
    report.append("- These tests compare PSAccel against native `Where-Object`, not against optimized CPU implementations.")
    report.append("- Shapiro-Wilk results should be interpreted cautiously because each method has `n=5` trials per scenario/tier.")
    report.append("- Welch t-tests are reported as the robust default for unequal variance assumptions.")
    report.append("- Mann-Whitney U tests are provided as a nonparametric backup, not as a replacement for reporting practical effect size.")
    report.append("- Positive Cohen's d values indicate that CPU `Where-Object` had larger elapsed times than PSAccel.")
    report.append("- Statistical significance and practical speedup should be discussed separately.")
    (output_dir / "primary_statistical_analysis_report.md").write_text("\n".join(report) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run primary PSAccel framework-replacement statistical analysis.")
    parser.add_argument("--run-root", required=True, type=Path, help="FrameworkReplacementOfficial run folder.")
    parser.add_argument("--output-root", required=True, type=Path, help="Folder under which a timestamped analysis folder is created.")
    parser.add_argument("--analysis-id", default=None, help="Optional fixed analysis folder name.")
    args = parser.parse_args()

    run_root = args.run_root.resolve()
    observations_path = run_root / "framework_replacement_observations.csv"
    skipped_path = run_root / "framework_replacement_skipped_scenarios.json"
    if not observations_path.exists():
        raise FileNotFoundError(observations_path)

    analysis_id = args.analysis_id or f"PrimaryStatisticalAnalysis-{utc_stamp()}"
    output_dir = args.output_root.resolve() / analysis_id
    if output_dir.exists():
        raise FileExistsError(f"Refusing to overwrite existing analysis folder: {output_dir}")
    output_dir.mkdir(parents=True)

    raw_rows = read_csv_rows(observations_path)
    official_rows = [
        r
        for r in raw_rows
        if not truthy(r.get("Warmup")) and truthy(r.get("OfficialAnalysisEligible")) and safe_float(r.get("StopwatchElapsedMs")) is not None
    ]
    bad_counts = [r for r in official_rows if not truthy(r.get("CountMatchesExpected"))]
    exceptions = [r for r in official_rows if str(r.get("Exception", "")).strip()]
    if bad_counts:
        raise RuntimeError(f"Count mismatches found in official observations: {len(bad_counts)}")
    if exceptions:
        raise RuntimeError(f"Exceptions found in official observations: {len(exceptions)}")

    grouped: dict[tuple[str, str, str, str, str, str], list[dict[str, str]]] = {}
    for r in official_rows:
        key = (
            r["WorkloadGroup"],
            r["ScenarioName"],
            r["DatasetMode"],
            r["DatasetSize"],
            r["PredicateName"],
            r["SelectivityLabel"],
        )
        grouped.setdefault(key, []).append(r)

    comparisons: list[dict[str, Any]] = []
    descriptives: list[dict[str, Any]] = []
    for key in sorted(grouped.keys(), key=lambda x: (x[0], x[1], int(x[3]))):
        comparison, desc = test_row(key, grouped[key])
        comparisons.append(comparison)
        descriptives.extend(desc)

    write_csv(output_dir / "primary_statistical_tests_by_scenario.csv", comparisons)
    write_json(output_dir / "primary_statistical_tests_by_scenario.json", comparisons)
    write_csv(output_dir / "primary_method_descriptives_by_scenario.csv", descriptives)
    write_json(output_dir / "primary_method_descriptives_by_scenario.json", descriptives)
    build_report(
        output_dir=output_dir,
        run_root=run_root,
        observations_path=observations_path,
        comparisons=comparisons,
        descriptives=descriptives,
        skipped_path=skipped_path if skipped_path.exists() else None,
    )

    marker = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "primary_analysis_dataset": "FrameworkReplacementOfficial-20260610T145621",
        "run_root": str(run_root),
        "observations_path": str(observations_path),
        "observations_sha256": file_sha256(observations_path),
        "analysis_folder": str(output_dir),
        "official_observation_count": len(official_rows),
        "scenario_tier_comparisons": len(comparisons),
        "tests": [
            "Shapiro-Wilk per method",
            "Levene/Brown-Forsythe variance test",
            "Welch independent-samples t-test",
            "Mann-Whitney U backup",
            "Cohen's d",
            "95% CI for method means",
            "95% CI for CPU minus PSAccel mean reduction",
        ],
        "baseline": "native PowerShell Where-Object",
        "psaccel_condition": "PSA_Where-Object",
        "optimized_cpu_baselines_included": False,
        "count_mismatches": len(bad_counts),
        "observation_exceptions": len(exceptions),
    }
    write_json(output_dir / "PRIMARY_ANALYSIS_DATASET.json", marker)

    files = sorted([p for p in output_dir.iterdir() if p.is_file()])
    hashes = []
    for path in files:
        if path.name in {"artifact_manifest.json", "sha256sums.txt"}:
            continue
        hashes.append(
            {
                "relative_path": path.name,
                "length": path.stat().st_size,
                "sha256": file_sha256(path),
            }
        )
    write_json(
        output_dir / "artifact_manifest.json",
        {
            "generated_utc": datetime.now(timezone.utc).isoformat(),
            "analysis_folder": str(output_dir),
            "source_observations": str(observations_path),
            "source_observations_sha256": file_sha256(observations_path),
            "files": hashes,
        },
    )
    sha_lines = [f"{item['sha256']}  {item['relative_path']}" for item in hashes]
    (output_dir / "sha256sums.txt").write_text("\n".join(sha_lines) + "\n", encoding="utf-8")

    print(json.dumps(marker, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
