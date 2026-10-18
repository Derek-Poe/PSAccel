"""Verify current-run evidence and write descriptive summaries (Python stdlib only)."""
import argparse
import csv
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path
from statistics import fmean, median, quantiles, stdev

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = Path(__file__).resolve().parent / 'results' / '2026-10-18-integrated-gpu'
METHODS = ('WhereObject', 'PSAccelPipeline', 'PSAccelInputData', 'CSharpLoop')


def require(value, message):
    if not value:
        raise AssertionError(message)


def load_and_verify(directory):
    environment = json.loads((directory / 'environment.json').read_text(encoding='utf-8-sig'))
    raw = (directory / 'observations.csv').read_bytes()
    require(hashlib.sha256(raw).hexdigest() == environment['observations_sha256'], 'Raw observation checksum differs')
    for source in environment['source_files']:
        canonical = (ROOT / source['path']).read_text(encoding='utf-8-sig').replace('\r\n', '\n').encode('utf-8')
        require(hashlib.sha256(canonical).hexdigest() == source['sha256_utf8_lf_without_bom'],
                'Measured source differs: ' + source['path'])
    with (directory / 'observations.csv').open(encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.DictReader(stream))
    require(len(rows) == environment['observations'], 'Observation total differs')
    expected_total = len(environment['sizes']) * 2 * len(METHODS) * (environment['warmup_runs'] + environment['measured_repetitions'])
    require(len(rows) == expected_total, 'Incomplete case coverage')
    groups = defaultdict(list)
    expected = {}
    for size in environment['sizes']:
        for scenario in ('SingleProperty', 'ThreeProperty'):
            # Independently reconstruct the known mathematical selection, not a measured method's output.
            indices = [i for i in range(size) if
                       ((i * 37) % 1000 >= 900 if scenario == 'SingleProperty' else
                        ((i * 37) % 1000 >= 500 and (i * 13) % 17 < 4) or (i * 19) % 23 == 0)]
            digest = hashlib.sha256(''.join(f'{i}\n' for i in indices).encode('utf-8')).hexdigest()
            expected[(scenario, size)] = len(indices), digest
    for row in rows:
        key = row['scenario'], int(row['rows'])
        require(key in expected, 'Unexpected case')
        require(row['host_label'] == 'integrated_gpu_host_01', 'Unexpected host label')
        require(row['module_version'] == environment['module_version'], 'Version mismatch')
        require(row['method'] in METHODS and row['phase'] in ('warmup', 'measured'), 'Unexpected method or phase')
        require(row['exact_identity_and_order'].lower() == 'true', 'Identity check failed')
        require((int(row['result_count']), row['result_id_sha256']) == expected[key], 'Independent result fixture differs')
        elapsed = float(row['elapsed_ms'])
        require(math.isfinite(elapsed) and elapsed > 0, 'Invalid elapsed time')
        require(all(int(row[f'gc{i}']) >= 0 for i in range(3)), 'Invalid GC delta')
        groups[key + (row['method'], row['phase'])].append(row)
    for scenario, size in expected:
        for phase, repetitions in [('warmup', environment['warmup_runs']), ('measured', environment['measured_repetitions'])]:
            for method in METHODS:
                trials = groups[(scenario, size, method, phase)]
                require(len(trials) == repetitions, 'Missing/duplicate trials')
                require({int(r['repeat']) for r in trials} == set(range(1, repetitions + 1)), 'Trial numbering differs')
                if phase == 'measured' and repetitions % 4 == 0:
                    require(all(sum(int(r['order_position']) == i for r in trials) == repetitions // 4 for i in range(1, 5)), 'Unbalanced method positions')
            for repeat in range(1, repetitions + 1):
                positions = [int(r['order_position']) for method in METHODS
                             for r in groups[(scenario, size, method, phase)] if int(r['repeat']) == repeat]
                require(sorted(positions) == [1, 2, 3, 4], 'Round order differs')
    return environment, groups


def summarize(groups):
    summary = []
    for (scenario, size, method, phase), trials in sorted(groups.items()):
        if phase != 'measured':
            continue
        samples = [float(row['elapsed_ms']) for row in trials]
        q1, _, q3 = quantiles(samples, n=4, method='inclusive')
        summary.append(dict(scenario=scenario, rows=size, method=method, trials=len(samples),
                            median_ms=round(median(samples), 6), mean_ms=round(fmean(samples), 6),
                            min_ms=min(samples), q1_ms=round(q1, 6), q3_ms=round(q3, 6), max_ms=max(samples),
                            stddev_ms=round(stdev(samples), 6), result_count=int(trials[0]['result_count'])))
    by_case = defaultdict(dict)
    for row in summary:
        by_case[(row['scenario'], row['rows'])][row['method']] = row
    ratios = []
    for (scenario, size), methods in sorted(by_case.items()):
        native = methods['WhereObject']['median_ms']
        cpu = methods['CSharpLoop']['median_ms']
        pipeline = methods['PSAccelPipeline']['median_ms']
        array = methods['PSAccelInputData']['median_ms']
        ratios.append(dict(scenario=scenario, rows=size,
                           native_over_psaccel_pipeline=round(native / pipeline, 6),
                           native_over_psaccel_inputdata=round(native / array, 6),
                           psaccel_pipeline_over_csharp=round(pipeline / cpu, 6),
                           psaccel_inputdata_over_csharp=round(array / cpu, 6)))
    return summary, ratios


def write_csv(path, rows):
    with path.open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path, default=DEFAULT)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    environment, groups = load_and_verify(args.directory)
    summary, ratios = summarize(groups)
    if args.verify_only:
        for filename, recomputed in [('summary.csv', summary), ('ratios.csv', ratios)]:
            with (args.directory / filename).open(encoding='utf-8', newline='') as stream:
                stored = list(csv.DictReader(stream))
            require(stored == [{key: str(value) for key, value in row.items()} for row in recomputed], filename + ' differs from recomputed values')
    else:
        write_csv(args.directory / 'summary.csv', summary)
        write_csv(args.directory / 'ratios.csv', ratios)
    print(f"PASS: {environment['observations']} observations, {environment['measured_observations']} measured; source hashes, independent result fixtures, trial coverage and descriptive summaries verified")
    for row in ratios:
        print(json.dumps(row))


if __name__ == '__main__':
    main()
