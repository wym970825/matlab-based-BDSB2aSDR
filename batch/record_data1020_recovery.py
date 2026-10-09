"""Record and verify crash-recovery provenance using streamed file hashes."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        while block := f.read(1024 * 1024):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = read(root / "manifest.json")
    path = root / "recovery_audit.json"
    if args.verify:
        audit = read(path)
        mismatches = [r["path"] for r in audit["preservedFinals"]
                      if not Path(r["path"]).is_file() or digest(r["path"]) != r["sha256"]]
        audit["preservedFinalsUnchanged"] = not mismatches
        audit["changedOrMissingFinals"] = mismatches
        completed = []
        for e in manifest["entries"]:
            vpath = Path(e["tfDir"]) / "validation.json"
            if vpath.is_file() and read(vpath).get("pipelineOk") is True:
                completed.append(e["experimentNumber"])
        audit["completedTfExperiments"] = completed
        audit["recoveryComplete"] = completed == list(range(1, 7)) and not mismatches
        audit["verifiedUtc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        audit["recoveryPlans"] = [str(Path(e["tfDir"]) / "recovery_plan.json")
                                  for e in manifest["entries"][4:]]
        path.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
        if mismatches or not audit["recoveryComplete"]:
            raise SystemExit("Recovery not complete or preserved final files changed")
    elif not path.exists():
        e = manifest["entries"][4]
        finals = []
        for prn in [24, 27, 28, 32, 33, 38, 39, 41]:
            source = Path(e["tfDir"]) / "temp" / f"Trk_Prn_{prn:02d}_final.mat"
            stat = source.stat()
            finals.append({"PRN": prn, "path": str(source), "bytes": stat.st_size,
                           "mtimeNs": stat.st_mtime_ns, "sha256": digest(source)})
        audit = {
            "createdUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "recoveryComplete": False, "preservedFinals": finals,
            "completedBeforeCrash": [1, 2, 3, 4], "interruptedExperiment": 5,
            "restartWholeChannels": [25, 30], "loopStateCheckpointAvailable": False,
            "oldPrn25SavedChunkSeconds": 120, "lastLoggedPrn25Seconds": 156.8,
            "splicingOldAndRestartedTracking": False,
            "execution": {"matlabVersion": "R2024b", "singleComputationalThread": True,
                          "parallelPool": False, "oneProcessPerStage": True,
                          "useParfor": False, "useParallelAcquisition": False, "parMaxWorkers": 1},
            "channelMetadataNote": "Reused finals retain original tracking data; lost post-REACQ channel metadata cannot be reconstructed. Navigation uses finals in original 63 slots.",
            "durationNote": "Experiment 5 elapsedSeconds covers recovery work only; its pre-crash partial computation and outage time are not comparable with uninterrupted run times.",
        }
        path.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"path": str(path), "recoveryComplete": read(path)["recoveryComplete"]}))


if __name__ == "__main__":
    main()
