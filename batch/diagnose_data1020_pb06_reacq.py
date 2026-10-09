"""Read only experiment 06 state/source-sample fields to describe REACQ timing.

No MATLAB, receiver replay, elevation qualification, or cause attribution.
Two bounded raw numeric arrays are retained for one satellite at a time.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import struct

from verify_data1020_recovered_chunk import HDF5, snapshot


def read_field(hdf, group, name):
    dataset = hdf.check(hdf.lib.H5Dopen2(group, name.encode("ascii"), 0), "open "+name)
    try:
        meta, raw, datatype = hdf.dataset(dataset, 8*1024*1024)
        try:
            assert meta["datatype"]["hdfClass"] in (0, 1), "Expected plain numeric field"
            assert meta["matlabEmpty"] is None, "Unexpected empty field"
            meta["uncompressedNumericBytesSha256"] = hashlib.sha256(raw).hexdigest()
            return meta, raw
        finally:
            hdf.lib.H5Tclose(datatype)
    finally:
        hdf.lib.H5Dclose(dataset)


def satellite(hdf, path, expected, fs):
    before = snapshot(path)
    source = hdf.open(path)
    try:
        group = hdf.check(hdf.lib.H5Gopen2(source, b"finalTRes", 0), "open finalTRes")
        try:
            state_meta, states = read_field(hdf, group, "trk_state")
            sample_meta, samples = read_field(hdf, group, "absoluteSample")
        finally:
            hdf.lib.H5Gclose(group)
    finally:
        hdf.lib.H5Fclose(source)
    count = state_meta["storedElementCount"]
    assert count == sample_meta["storedElementCount"] == expected["recordedMs"]
    sample_format = sample_meta["datatype"]["format"]
    sample_size = sample_meta["datatype"]["sizeBytes"]

    def tick_time(index):
        if not 0 <= index < count:
            return None
        value = struct.unpack_from(sample_format, samples, index*sample_size)[0]/fs
        return value if math.isfinite(value) else None

    episodes, active = [], None
    nonfinite, rewinds, duplicate_times = 0, 0, 0
    previous = None
    for index, ((state,), (absolute,)) in enumerate(zip(
            struct.iter_unpack(state_meta["datatype"]["format"], states),
            struct.iter_unpack(sample_format, samples))):
        current = absolute/fs
        if not math.isfinite(current):
            nonfinite += 1
        elif previous is not None:
            rewinds += current < previous
            duplicate_times += current == previous
        previous = current if math.isfinite(current) else None
        if state == 9 and active is None:
            active = index
        if active is not None and (state != 9 or index == count-1):
            last = index-1 if state != 9 else index
            start_time, last_time = tick_time(active), tick_time(last)
            n = last-active+1
            # trackOneChannel reads round(Fs*1e-3) complete samples for each
            # successfully saved REACQ slot, logging its start before read.
            block_seconds = round(fs*1e-3)/fs
            contiguous = all(tick_time(i) is not None and tick_time(i-1) is not None and
                             abs(tick_time(i)-tick_time(i-1)-block_seconds) <= 2/fs
                             for i in range(active+1, last+1))
            episodes.append({
                "episodeNumber": len(episodes)+1, "firstRowOneBased": active+1,
                "lastRowOneBased": last+1, "reacqRecords": n,
                "episodeStartSourceSeconds": start_time,
                "episodeLastTickStartSourceSeconds": last_time,
                "episodeEndSourceSeconds": None if last_time is None else last_time+block_seconds,
                "readBlockDurationSumSeconds": n*block_seconds,
                "sourceTickIntervalsContiguous": contiguous,
                "previousRecordSourceSeconds": tick_time(active-1),
                "nextRecordSourceSeconds": tick_time(last+1),
            })
            active = None
    after = snapshot(path)
    unchanged = all(before[k] == after[k] for k in ("sizeBytes", "mtimeNs"))
    assert unchanged, "Source MAT changed during diagnostic"
    assert len(episodes) == expected["reacqEpisodes"], "Episode count disagrees with saved validation"
    assert sum(e["reacqRecords"] for e in episodes) == expected["reacqMs"]
    return {"PRN": expected["PRN"], "source": before, "sourceUnchanged": unchanged,
            "recordCount": count, "reacqEpisodeCount": len(episodes),
            "reacqRecords": sum(e["reacqRecords"] for e in episodes),
            "nonfiniteSourceTimes": nonfinite, "sourceRewinds": rewinds,
            "duplicateConsecutiveSourceTimes": duplicate_times,
            "fields": {"trk_state": state_meta, "absoluteSample": sample_meta},
            "episodes": episodes}


def dense_window(events, width):
    best = []
    for start in events:
        selected = [e for e in events if 0 <= e["episodeStartSourceSeconds"]-
                    start["episodeStartSourceSeconds"] <= width]
        if (len({e["PRN"] for e in selected}), len(selected)) > (len({e["PRN"] for e in best}), len(best)):
            best = selected
    return {"windowSeconds": width, "distinctPrnCount": len({e["PRN"] for e in best}),
            "PRNs": sorted({e["PRN"] for e in best}), "eventCount": len(best),
            "firstEventStartSeconds": best[0]["episodeStartSourceSeconds"] if best else None,
            "lastEventStartSeconds": best[-1]["episodeStartSourceSeconds"] if best else None,
            "actualStartSpreadSeconds": best[-1]["episodeStartSourceSeconds"]-
                best[0]["episodeStartSourceSeconds"] if best else None,
            "events": best}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--method", type=str.upper, choices=("PB", "TF"), default="PB",
                        help="Completed experiment 06 result set to read (default: PB)")
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = json.loads((root/"manifest.json").read_text(encoding="utf-8-sig"))
    entry = next(e for e in manifest["entries"] if e["experimentNumber"] == 6)
    assert entry["sourceId"] == "111407"
    run = Path(entry["pbDir"] if args.method == "PB" else entry["tfDir"])
    validation_path = run/"validation.json"
    if not validation_path.is_file():
        raise SystemExit("Refusing partial analysis: completed run validation.json is required")
    validation = json.loads(validation_path.read_text(encoding="utf-8-sig"))
    if validation.get("pipelineOk") is not True or validation.get("stage") != "done":
        raise SystemExit("Refusing partial analysis: the selected receiver run is not complete")
    acquired = validation.get("acquiredPrns", [])
    acquired = [acquired] if isinstance(acquired, (int, float)) else acquired
    acquired = sorted(int(p) for p in acquired)
    tracks = validation.get("tracks", [])
    tracks = [tracks] if isinstance(tracks, dict) else tracks
    acquisition_path = run/"acquisition_summary.csv"
    if not acquisition_path.is_file():
        raise SystemExit("Refusing partial analysis: acquisition_summary.csv is required")
    with acquisition_path.open(encoding="utf-8-sig", newline="") as stream:
        acquisition = list(csv.DictReader(stream))
    detected = sorted(int(r["PRN"]) for r in acquisition if r["detected"].lower() in ("1", "true"))
    files = list((run/"temp").glob("Trk_Prn_*_final.mat"))
    expected_files = {f'Trk_Prn_{p:02d}_final.mat' for p in acquired}
    complete_set = (bool(acquired) and validation.get("allAcquiredTracked") is True and
                    validation.get("nAcquired") == len(acquired) == len(set(acquired)) and
                    sorted(int(r["PRN"]) for r in acquisition) == list(range(1, 64)) and
                    detected == acquired == sorted(int(r["PRN"]) for r in tracks) and
                    {p.name for p in files} == expected_files and
                    all(p.stat().st_size > 0 for p in files))
    if not complete_set:
        raise SystemExit("Refusing partial analysis: acquisition, validation, and every acquired PRN final must form the same complete set")
    library = Path("C:/Program Files/MATLAB/R2024b/bin/win64/hdf5.dll")
    hdf = HDF5(library)
    records = []
    for expected in tracks:
        path = run/"temp"/f'Trk_Prn_{expected["PRN"]:02d}_final.mat'
        records.append(satellite(hdf, path, expected, entry["samplingFreq"]))
    events = sorted((dict(PRN=r["PRN"], **e) for r in records for e in r["episodes"]
                     if e["episodeStartSourceSeconds"] is not None),
                    key=lambda e: e["episodeStartSourceSeconds"])
    windows = [dense_window(events, width) for width in (1, 2, 5)]
    best = windows[1]
    observed = (f'{best["distinctPrnCount"]} distinct PRNs have REACQ episode starts within '
                f'{best["actualStartSpreadSeconds"]:.6f} source seconds in the densest 2-second window.'
                if events else "No saved REACQ episodes in the complete acquired-satellite result set.")
    result = {
        "generatedUtc": dt.datetime.now(dt.timezone.utc).isoformat(), "ok": True,
        "experimentNumber": 6, "sourceId": entry["sourceId"], "method": args.method,
        "acquiredPrns": acquired, "analyzedPrns": sorted(r["PRN"] for r in records),
        "completeAcquiredFinalSet": complete_set,
        "samplingFrequencyHz": entry["samplingFreq"], "matlabLaunched": False,
        "receiverRerun": False, "sourceDataModified": False, "hdf5Library": str(library),
        "readScope": "Only finalTRes.trk_state and finalTRes.absoluteSample from one final MAT at a time; at most 8 MiB per raw numeric field. Other tracking arrays and raw IQ are not read.",
        "episodeDefinition": "Consecutive saved rows whose trk_state equals 9; event starts and last-record starts use absoluteSample/Fs. End adds round(Fs*1ms)/Fs, per trackOneChannel.m REACQ full-block read/log behavior; adjacent tick continuity is checked separately.",
        "densityDefinition": "Densest episode-start windows of 1, 2 and 5 source seconds, maximizing distinct PRNs then event count; descriptive windows, not statistical cause tests.",
        "observed": observed,
        "limits": ["Source time is recording-relative, not wall-clock CPU time or first-fix UTC.",
                   "Temporal clustering does not establish raw-IQ loss, DME interference, or a receiver defect; none is diagnosed here.",
                   "Source-coordinate rewinds can occur during receiver rereads; they do not alone establish a discontinuity in the raw recording.",
                   "This is not the formal 180-second continuity/elevation qualification and does not change its definitions.",
                   "Source unchanged checks use size/mtime; per-field hashes describe the two decompressed numeric fields, not the full MAT container."],
        "satelliteCount": len(records), "totalReacqEpisodes": len(events),
        "records": records, "episodesBySourceTime": events, "densestEpisodeStartWindows": windows,
    }
    output = root/"analysis"/f'{args.method.lower()}06_reacq_timing_diagnostic.json'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps({"ok": True, "output": str(output), "observed": result["observed"],
                      "events": [{k:e[k] for k in ["PRN", "episodeNumber", "episodeStartSourceSeconds", "episodeEndSourceSeconds"]}
                                 for e in events]}, ensure_ascii=True))


if __name__ == "__main__":
    main()
