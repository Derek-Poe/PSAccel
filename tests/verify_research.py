"""Check public export integrity and independently recompute descriptive results."""
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from statistics import fmean

ROOT = Path(__file__).resolve().parents[1]
RESEARCH = ROOT / "research"
RUN = RESEARCH / "FrameworkReplacementOfficial-20260610T145621"


def rows(name):
    with (RUN / name).open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def require(condition, message):
    if not condition:
        raise AssertionError(message)


manifest = json.loads((RESEARCH / "provenance.json").read_text(encoding="utf-8"))
for item in manifest["files"]:
    file = ROOT / item["path"]
    require(hashlib.sha256(file.read_bytes()).hexdigest() == item["public_sha256"],
            f"Public checksum mismatch: {item['path']}")

observations = rows("framework_replacement_observations.csv")
require(len(observations) == 110, "Expected 110 measured observations")
require(len(rows("framework_replacement_warmups.csv")) == 22, "Expected 22 separate warmups")
groups = defaultdict(lambda: defaultdict(list))
for row in observations:
    require(row["Warmup"].lower() == "false", "Warmup in measured data")
    require(row["OfficialAnalysisEligible"].lower() == "true", "Ineligible observation")
    require(not row["Exception"].strip(), "Observation exception")
    require(int(row["ResultCount"]) == int(row["ExpectedCount"]), "Result count mismatch")
    require(row["CountMatchesExpected"].lower() == "true", "Count marker mismatch")
    require(row["MachineName"] == "benchmark-host", "Non-example host label")
    require(row["PSAccelCommit"] == manifest["measured_source_commit"], "Source mismatch")
    require(float(row["StopwatchElapsedMs"]) > 0, "Nonpositive duration")
    key = row["ScenarioName"], row["DatasetSize"]
    groups[key][row["Method"]].append(row)
require(len(groups) == 11, "Expected 11 comparison groups")
comparisons = {(r["ScenarioName"], r["DatasetSize"]): r
               for r in rows("framework_replacement_comparison.csv")}
require(set(comparisons) == set(groups), "Comparison coverage mismatch")
for key, methods in groups.items():
    require(set(methods) == {"CPUWhereObject", "PSAccelWhereObject"}, "Unexpected method")
    for trials in methods.values():
        require(len(trials) == 5 and {int(r["Trial"]) for r in trials} == set(range(1, 6)),
                "Repeated or missing trial")
    cpu = fmean(float(r["StopwatchElapsedMs"]) for r in methods["CPUWhereObject"])
    gpu = fmean(float(r["StopwatchElapsedMs"]) for r in methods["PSAccelWhereObject"])
    comparison = comparisons[key]
    require(abs(cpu - float(comparison["CPU_MeanMs"])) <= .00051, "CPU mean mismatch")
    require(abs(gpu - float(comparison["PSAccel_MeanMs"])) <= .00051, "PSAccel mean mismatch")
    require(abs(cpu / gpu - float(comparison["SpeedupRatio"])) <= .000051, "Ratio mismatch")
print(f"PASS: {len(manifest['files'])} research hashes, 110 observations, 22 warmups, 11 comparisons")
