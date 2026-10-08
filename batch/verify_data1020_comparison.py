"""Independently verify exported PB/TF comparison metrics (standard library).

Usage: python batch/verify_data1020_comparison.py COMPARISON_DIR
Writes COMPARISON_DIR/comparison_validation.json; exits 0 on success, 1 on
failure. This validates interval arithmetic and report consistency without
loading MATLAB or rereading IQ data. The package validator owns settings,
source identity, source immutability, images, and other artifact checks.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sys


CRITERIA = {
    "no_reacq": ("longestNoReacqSeconds", "noReacq180"),
    "long_state": ("longestLongStateSeconds", "longState180"),
    "no_reacq_above_30": ("longestNoReacqAbove30Seconds", "noReacqAbove30For180"),
    "long_state_above_30": ("longestLongStateAbove30Seconds", "longStateAbove30For180"),
}
PAIR_CRITERIA = {
    "no_reacq": ("commonNoReacqSeconds", "commonNoReacq180", "bothNoReacq180"),
    "long_state": ("commonLongStateSeconds", "commonLongState180", "bothLongState180"),
    "no_reacq_above_30": ("commonHighElevationSeconds", "commonHighElevation180", "bothHighElevation180"),
    "long_state_above_30": ("commonLongHighElevationSeconds", "commonLongHighElevation180", "bothLongHighElevation180"),
}
FRONTEND_SUFFIXES = (
    "DetectorDuty", "MeanWeight", "MeanWeightSquared", "WeightSupportFraction"
)


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def same_number(a, b, *, absolute=1e-7, relative=1e-12):
    if a is None or b is None:
        return a is None and b is None
    return finite(a) and finite(b) and math.isclose(a, b, abs_tol=absolute, rel_tol=relative)


def key(row):
    return int(row["experimentNumber"]), str(row["mode"]), int(row["PRN"])


def pair_key(row):
    return int(row["experimentNumber"]), int(row["PRN"])


def maximum_length(intervals):
    return max((end - start for start, end in intervals), default=0.0)


def intersections(a, b):
    # Keep every source segment separate. Merging touching segments could
    # wrongly hide a reacquisition or source-time rewind at the join.
    result = []
    for start_a, end_a in a:
        for start_b, end_b in b:
            start, end = max(start_a, start_b), min(end_a, end_b)
            if end > start:
                result.append((start, end))
    return result


def contained(interval, parents):
    start, end = interval
    return any(start >= a - 1e-7 and end <= b + 1e-7 for a, b in parents)


def prns(value):
    return {int(item) for item in str(value or "").split()}


def canonical_path(value):
    return str(value).replace("\\", "/").rstrip("/").casefold()


class Audit:
    def __init__(self):
        self.failures = []
        self.warnings = []
        self.check_count = 0

    def check(self, condition, message):
        self.check_count += 1
        if not condition:
            self.failures.append(message)

    def number(self, actual, expected, message, **kwargs):
        self.check(same_number(actual, expected, **kwargs),
                   f"{message}: actual={actual!r}, expected={expected!r}")

    def csv(self, path, expected_rows):
        self.check(path.is_file(), f"Missing CSV: {path.name}")
        if not path.is_file():
            return
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            actual_rows = list(reader)
            headers = reader.fieldnames or []
        self.check(len(actual_rows) == len(expected_rows),
                   f"{path.name}: row count {len(actual_rows)} != {len(expected_rows)}")
        if not expected_rows:
            return
        self.check(set(headers) == set(expected_rows[0]), f"{path.name}: JSON/CSV column mismatch")
        for index, (actual, expected) in enumerate(zip(actual_rows, expected_rows), 1):
            for field, value in expected.items():
                cell = actual.get(field)
                label = f"{path.name} row {index}, {field}"
                if value is None:
                    self.check(cell in ("", "NaN", "nan"), f"{label}: missing numeric value differs")
                elif isinstance(value, bool):
                    self.check(cell in (("1", "true", "True") if value else ("0", "false", "False")),
                               f"{label}: boolean differs")
                elif isinstance(value, (int, float)):
                    try:
                        self.number(float(cell), value, label)
                    except (TypeError, ValueError):
                        self.check(False, f"{label}: invalid numeric cell {cell!r}")
                else:
                    self.check(cell == str(value), f"{label}: text differs")


def verify(folder: Path):
    audit = Audit()
    with (folder / "comparison_report.json").open(encoding="utf-8-sig") as handle:
        report = json.load(handle)
    metrics = as_list(report.get("satelliteMetrics", []))
    interval_rows = as_list(report.get("continuousIntervals", []))
    paired = as_list(report.get("pairedSatellites", []))
    experiments = as_list(report.get("experiments", []))
    summaries = [item["summary"] for item in experiments]
    definitions = report.get("definitions", {})
    audit.check(definitions.get("thresholdSeconds") == 180, "Unexpected duration threshold")
    audit.check(definitions.get("elevationThresholdDeg") == 30, "Unexpected elevation threshold")
    audit.check(bool(metrics), "No satellite metrics exported")
    by_metric = {key(row): row for row in metrics}
    by_pair = {pair_key(row): row for row in paired}
    experiment_ids = {int(row["experimentNumber"]) for row in summaries}
    audit.check(len(experiment_ids) == len(summaries), "Duplicate experiment summaries")
    audit.check({ident[0] for ident in by_metric} == experiment_ids,
                "Experiment summaries and satellite metric experiment sets differ")
    audit.check(len(by_metric) == len(metrics), "Duplicate experiment/mode/PRN metrics")
    audit.check(len(by_pair) == len(paired), "Duplicate paired satellite rows")
    intervals = {}
    for row in interval_rows:
        ident = key(row)
        criterion = row["criterion"]
        group = intervals.setdefault((*ident, criterion), [])
        start, end = row["fileStartSeconds"], row["fileEndSeconds"]
        audit.check(criterion in CRITERIA, f"{ident}: unknown interval criterion {criterion}")
        audit.check(ident in by_metric, f"{ident}: interval has no satellite metric")
        if not (finite(start) and finite(end) and end > start):
            audit.check(False, f"{ident}/{criterion}: invalid interval [{start}, {end}]")
            continue
        duration = end - start
        audit.number(row["durationSeconds"], duration, f"{ident}/{criterion}: interval duration")
        audit.check(row["atLeast180Seconds"] is (duration >= 180),
                    f"{ident}/{criterion}: incorrect >=180 flag")
        group.append((start, end))
        metric = by_metric.get(ident)
        if metric:
            audit.check(row["sourceId"] == metric["sourceId"] and
                        row["stationName"] == metric["stationName"],
                        f"{ident}/{criterion}: source/station metadata differs from metric")
            audit.check(start >= metric["fileStartSeconds"] - 1e-7 and
                        end <= metric["fileEndSeconds"] + 1e-7,
                        f"{ident}/{criterion}: interval outside recorded source-time span")

    for ident, row in by_metric.items():
        audit.check(row["mode"] in ("PB", "TF"), f"{ident}: unknown mode")
        audit.check(1 <= row["PRN"] <= 63, f"{ident}: out-of-range PRN")
        audit.check(row["fullLengthRecorded"] is (row["recordCount"] >= row["requestedRecordCount"]),
                    f"{ident}: full-length record flag mismatch")
        audit.number(row["recordedSpanSeconds"], row["fileEndSeconds"] - row["fileStartSeconds"],
                     f"{ident}: recorded source-time span")
        audit.check(row["reacqEpisodes"] >= 0 and row["reacqRecordedSeconds"] >= 0,
                    f"{ident}: negative reacquisition metrics")
        for criterion, (duration_field, flag_field) in CRITERIA.items():
            values = intervals.get((*ident, criterion), [])
            duration = maximum_length(values)
            audit.number(row[duration_field], duration, f"{ident}: independently recomputed {duration_field}")
            audit.check(row[flag_field] is (duration >= 180), f"{ident}: incorrect {flag_field}")
        for child, parent in (("long_state", "no_reacq"),
                              ("no_reacq_above_30", "no_reacq"),
                              ("long_state_above_30", "long_state"),
                              ("long_state_above_30", "no_reacq_above_30")):
            for interval in intervals.get((*ident, child), []):
                audit.check(contained(interval, intervals.get((*ident, parent), [])),
                            f"{ident}: {child} is not contained in one {parent} segment")
        if row["mode"] == "TF":
            audit.check(row["medianPbBlankingFraction"] is None,
                        f"{ident}: TF legacy PB blanking fraction must be missing")
            audit.check(row["pbBlankingFractionValidEpochs"] == 0,
                        f"{ident}: TF legacy PB blanking count must be zero")
        for prefix in ("medianFrontend", "sampleWeightedFrontend"):
            fields = [row.get(prefix + name) for name in FRONTEND_SUFFIXES]
            audit.check(all(value is None or finite(value) and 0 <= value <= 1 for value in fields),
                        f"{ident}: {prefix} must be missing or within [0,1]")
            if all(finite(value) for value in fields):
                _, mean, squared, support = fields
                audit.check(squared <= mean + 1e-12 and mean <= support + 1e-12,
                            f"{ident}: weight squared <= weight <= nonzero support violated")
                if row["mode"] == "PB":
                    audit.check(max(fields) - min(fields) < 1e-12,
                                f"{ident}: PB binary frontend statistics disagree")
        if row["noReacqAbove30For180"]:
            audit.check(row["elevationAcceptedEpochs"] >= 2 and
                        finite(row["elevationMaxDeg"]) and row["elevationMaxDeg"] > 30,
                        f"{ident}: high-elevation qualification lacks supporting elevation samples")

    expected_pairs = {(exp, prn) for exp, mode, prn in by_metric
                      if mode == "PB" and (exp, "TF", prn) in by_metric}
    audit.check(set(by_pair) == expected_pairs, "Paired rows do not equal PB/TF PRN intersection")
    for ident, row in by_pair.items():
        experiment, prn = ident
        pb_key, tf_key = (experiment, "PB", prn), (experiment, "TF", prn)
        if pb_key not in by_metric or tf_key not in by_metric:
            continue
        pb, tf = by_metric[pb_key], by_metric[tf_key]
        common_sets = {}
        for criterion, (duration_field, flag_field, both_flag) in PAIR_CRITERIA.items():
            common = intersections(intervals.get((*pb_key, criterion), []),
                                   intervals.get((*tf_key, criterion), []))
            common_sets[criterion] = common
            duration = maximum_length(common)
            audit.number(row[duration_field], duration, f"{ident}: independently recomputed {duration_field}")
            audit.check(row[flag_field] is (duration >= 180), f"{ident}: incorrect {flag_field}")
            metric_flag = CRITERIA[criterion][1]
            audit.check(row[both_flag] is (pb[metric_flag] and tf[metric_flag]),
                        f"{ident}: incorrect independent PB/TF qualification {both_flag}")
        high = common_sets["no_reacq_above_30"]
        start, end = row["commonHighElevationStartSeconds"], row["commonHighElevationEndSeconds"]
        if high:
            audit.number(end - start, maximum_length(high), f"{ident}: preferred common interval length")
            audit.check(any(same_number(start, a) and same_number(end, b) for a, b in high),
                        f"{ident}: selected preferred interval not one continuous PB/TF intersection")
        else:
            audit.check(start is None and end is None, f"{ident}: empty common interval has nonmissing bounds")
        for prefix, metric in (("pb", pb), ("tf", tf)):
            audit.number(row[prefix + "ReacqEpisodes"], metric["reacqEpisodes"], f"{ident}: {prefix} reacq count")
            audit.number(row[prefix + "MedianCnoDbHz"], metric["medianB2aCnoDbHz"], f"{ident}: {prefix} CNo")
            audit.check(canonical_path(row[prefix + "TrackingMat"]) == canonical_path(metric["trackingMat"]),
                        f"{ident}: {prefix} tracking path mismatch")
            for name in FRONTEND_SUFFIXES:
                audit.number(row.get(prefix + "MedianFrontend" + name), metric.get("medianFrontend" + name),
                             f"{ident}: {prefix} frontend {name}")
        for delta_field, pb_field, tf_field in (
            ("deltaMedianCnoDbHz", "pbMedianCnoDbHz", "tfMedianCnoDbHz"),
            ("deltaCommonHighElevationMedianCnoDbHz", "pbCommonHighElevationMedianCnoDbHz", "tfCommonHighElevationMedianCnoDbHz"),
        ):
            a, b = row[pb_field], row[tf_field]
            expected = b - a if finite(a) and finite(b) else None
            audit.number(row[delta_field], expected, f"{ident}: {delta_field}")

    for experiment in experiments:
        summary = experiment["summary"]
        index = int(summary["experimentNumber"])
        case_pairs = [row for row in paired if row["experimentNumber"] == index]
        audit.check(all(row["sourceId"] == summary["sourceId"] and
                        row["stationName"] == summary["stationName"] for row in case_pairs),
                    f"{index}: paired rows source/station identity differs from summary")
        for prefix, mode in (("pb", "PB"), ("tf", "TF")):
            rows = [row for row in metrics if row["experimentNumber"] == index and row["mode"] == mode]
            audit.check(all(row["sourceId"] == summary["sourceId"] and
                            row["stationName"] == summary["stationName"] for row in rows),
                        f"{index}: {prefix} source/station identity differs from summary")
            ids = {row["PRN"] for row in rows}
            audit.check(summary[prefix + "Acquired"] == len(rows), f"{index}: {prefix} acquired/tracked count")
            audit.check(prns(summary[prefix + "AcquiredPrns"]) == ids, f"{index}: {prefix} acquired PRN list")
            audit.check(summary[prefix + "FullLengthRecorded"] == sum(row["fullLengthRecorded"] for row in rows),
                        f"{index}: {prefix} full-length count")
            for field, flag in (("FullLengthPrns", "fullLengthRecorded"), ("NoReacq180Prns", "noReacq180")):
                audit.check(prns(summary[prefix + field]) == {row["PRN"] for row in rows if row[flag]},
                            f"{index}: {prefix}{field} list mismatch")
            audit.check(summary[prefix + "ReacqEpisodes"] == sum(row["reacqEpisodes"] for row in rows),
                        f"{index}: {prefix} reacq episode sum")
            stats = experiment[prefix + "Navigation"]
            for field, nav_field in (("FiniteNavigationEpochs", "finiteEpochs"),
                                     ("PlottedEpochs", "plottedEpochs"),
                                     ("RemovedJumpEpochs", "removedJumpEpochs"),
                                     ("HeightMedianM", "heightMedianM"),
                                     ("HeightMinM", "heightMinM"), ("HeightMaxM", "heightMaxM"),
                                     ("AbsHeightOver1000m", "absHeightOver1000m"),
                                     ("AbsHeightOver10000m", "absHeightOver10000m")):
                audit.number(summary[prefix + field], stats[nav_field], f"{index}: {prefix}{field}")
            audit.check(stats["finiteEpochs"] == stats["plottedEpochs"] + stats["removedJumpEpochs"],
                        f"{index}: {prefix} finite/plotted/removed nav counts do not reconcile")
            root_path = canonical_path(experiment[prefix + "Path"]) + "/"
            audit.check(all(canonical_path(row["trackingMat"]).startswith(root_path) for row in rows),
                        f"{index}: {prefix} metrics point outside corresponding experiment folder")
        for field, flag in (("bothNoReacq180Prns", "bothNoReacq180"),
                            ("bothHighElevation180Prns", "bothHighElevation180"),
                            ("commonHighElevation180Prns", "commonHighElevation180"),
                            ("commonLongHighElevation180Prns", "commonLongHighElevation180")):
            audit.check(prns(summary[field]) == {row["PRN"] for row in case_pairs if row[flag]},
                        f"{index}: {field} list mismatch")
        delta = experiment["positionDisagreement"]
        for field, delta_field in (("matchedPositionEpochs", "matchedEpochs"),
                                   ("medianHorizontalDisagreementM", "horizontalMedianM"),
                                   ("p95HorizontalDisagreementM", "horizontalP95M"),
                                   ("medianAbsoluteHeightDisagreementM", "absoluteHeightMedianM"),
                                   ("p95AbsoluteHeightDisagreementM", "absoluteHeightP95M")):
            audit.number(summary[field], delta[delta_field], f"{index}: {field}")
        if canonical_path(experiment["pbPath"]) == canonical_path(experiment["tfPath"]):
            for field in ("horizontalMedianM", "horizontalP95M", "absoluteHeightMedianM", "absoluteHeightP95M"):
                audit.number(delta[field], 0, f"{index}: self-comparison {field}", absolute=1e-9)
            for row in case_pairs:
                audit.number(row["deltaMedianCnoDbHz"], 0, f"{index}/{row['PRN']}: self-comparison CNo", absolute=1e-9)

    csv_sources = {
        "comparison_summary.csv": summaries,
        "satellite_tracking_metrics.csv": metrics,
        "continuous_tracking_intervals.csv": interval_rows,
        "paired_satellites.csv": paired,
        "no_reacq_180s.csv": [row for row in metrics if row["noReacq180"]],
        "long_state_180s.csv": [row for row in metrics if row["longState180"]],
        "common_no_reacq_180s.csv": [row for row in paired if row["bothNoReacq180"]],
        "common_high_elevation_180s.csv": [row for row in paired if row["bothHighElevation180"]],
        "common_high_elevation_same_interval_180s.csv": [row for row in paired if row["commonHighElevation180"]],
        "common_long_high_elevation_same_interval_180s.csv": [row for row in paired if row["commonLongHighElevation180"]],
    }
    for filename, rows in csv_sources.items():
        audit.csv(folder / filename, rows)
    output = {
        "ok": not audit.failures,
        "generatedUtc": datetime.now(timezone.utc).isoformat(),
        "comparisonDirectory": str(folder.resolve()),
        "checks": audit.check_count,
        "failures": audit.failures,
        "warnings": audit.warnings,
        "counts": {"experiments": len(experiments), "satelliteModes": len(metrics),
                   "continuousIntervals": len(interval_rows), "pairedSatellites": len(paired),
                   "commonHighElevation180": sum(row["commonHighElevation180"] for row in paired),
                   "commonLongHighElevation180": sum(row["commonLongHighElevation180"] for row in paired)},
        "scope": "Independent Python recomputation of maxima, interval containment, PB/TF intersections, qualification flags and lists; JSON/CSV agreement, frontend-unit invariants and self-comparison zero differences when applicable.",
        "limitations": "Reads exported intervals rather than raw MAT ticks/elevations. It does not independently prove state labels, elevation geometry, source identity or unchanged receiver settings; these require MATLAB/raw-source and package-level evidence. No position-accuracy claim is validated.",
    }
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("comparison_directory", type=Path)
    args = parser.parse_args()
    folder = args.comparison_directory
    try:
        output = verify(folder)
    except Exception as error:
        output = {"ok": False, "generatedUtc": datetime.now(timezone.utc).isoformat(),
                  "failures": [f"{type(error).__name__}: {error}"], "checks": 0}
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "comparison_validation.json").write_text(
        json.dumps(output, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({"ok": output["ok"], "checks": output.get("checks", 0),
                      "failures": output.get("failures", [])[:10]}, ensure_ascii=False))
    return 0 if output["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
