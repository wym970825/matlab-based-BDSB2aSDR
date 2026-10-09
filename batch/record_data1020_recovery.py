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


def verify_replayed_chunk(root, manifest):
    """Verify the identity and source hashes of an existing field comparison.

    This does not load MAT arrays or independently repeat the field comparison.
    The two MAT container hashes need not equal one another.
    """
    root = Path(root).resolve()
    path = root / "analysis" / "recovered_prn25_chunk001_verification.json"
    result = {
        "ok": False, "path": str(path), "experimentNumber": 5, "PRN": 25,
        "chunkIndex": 1, "recordCount": 60000, "sourceHashesVerified": False,
        "scope": "Only PRN25 chunk 001 (first 60000 saved records), not every epoch or channel. Rechecks evidence identity and each MAT source hash; does not repeat numeric comparisons. Different MAT container hashes do not imply different numeric values.",
        "errors": [],
    }
    errors = result["errors"]

    def require(condition, message):
        if not condition:
            errors.append(message)

    try:
        evidence = read(path)
        result["sha256"] = digest(path)
        require(evidence.get("ok") is True, "Evidence ok is not true")
        require(evidence.get("sourceFilesUnchangedDuringComparison") is True,
                "Sources were not stable during the field comparison")
        require(evidence.get("errors") == [], "Evidence contains errors")
        numeric, metadata = evidence.get("numericFields", []), evidence.get("metadataFields", [])
        for name, fields, count in [("numeric", numeric, 83), ("metadata", metadata, 8)]:
            result[name + "FieldsCompared"] = evidence.get(name + "FieldsCompared")
            require(evidence.get(name + "FieldsCompared") == count and len(fields) == count,
                    name + " field count does not match the audited chunk")
            require(evidence.get(name + "FieldsUnequal") == [], name + " unequal fields recorded")
            require(len({f.get("field") for f in fields}) == len(fields), name + " duplicate field names")
            require(all(f.get("equal") is True and f.get("sameShape") is True and
                        f.get("sameType") is True for f in fields), name + " equality/shape/type check failed")
        require(all(f.get("numericValuesEqual") is True and f.get("mismatchedStoredElements") == 0
                    for f in numeric), "Numeric equality details are inconsistent")
        require(all(f.get("oldText") == f.get("newText") for f in metadata),
                "Character metadata equality details are inconsistent")
        fields = {f.get("field"): f for f in numeric}
        for name, expected in [("PRN", 25), ("Nsize", 60000), ("ChunkCapacity", 60000)]:
            field = fields.get("chunk/" + name, {})
            require(field.get("oldScalar") == expected and field.get("newScalar") == expected,
                    name + " does not identify the expected PRN/chunk length")
        for name in ["I_P", "Q_P", "absoluteSample", "trk_state"]:
            field = fields.get("chunk/" + name, {})
            require(all(field.get(side, {}).get("storedElementCount") == 60000 and
                        field.get(side, {}).get("hdfShape") == [60000, 1] for side in ["old", "new"]),
                    name + " does not contain 60000 records")
        entry = next(e for e in manifest["entries"] if e["experimentNumber"] == 5)
        require(entry.get("sourceId") == "103801", "Experiment 5 is not source 103801")
        expected_new = (Path(entry["tfDir"]) / "temp" / "Trk_Prn_25_001.mat").resolve()
        archive_root = root / "recovery_archive" / "exp05"
        sources = {}
        hashes_ok = True
        for side in ["old", "new"]:
            source = evidence.get(side, {})
            source_path = Path(source.get("path", "")).resolve()
            if side == "old":
                identity_ok = (source_path.name == "Trk_Prn_25_001.mat" and
                               source_path.parent.parent == archive_root and
                               source_path.parent.name.startswith("prn25_"))
            else:
                identity_ok = source_path == expected_new
            require(identity_ok, side + " source path does not identify the expected chunk")
            file_ok = (identity_ok and source_path.is_file() and
                       source_path.stat().st_size == source.get("sizeBytes") and
                       digest(source_path) == source.get("sha256"))
            require(file_ok, side + " source size/hash does not match the evidence")
            hashes_ok = hashes_ok and file_ok
            sources[side] = {"path": str(source_path), "sha256": source.get("sha256"),
                             "sizeBytes": source.get("sizeBytes")}
        result["sources"] = sources
        result["sourceHashesVerified"] = hashes_ok
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as exc:
        errors.append(type(exc).__name__ + ": " + str(exc))
    result["ok"] = not errors
    return result


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
        audit["replayedChunkVerification"] = verify_replayed_chunk(root, manifest)
        audit["recoveryComplete"] = (completed == list(range(1, 7)) and not mismatches and
                                     audit["replayedChunkVerification"]["ok"])
        audit["verifiedUtc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        audit["recoveryPlans"] = [str(Path(e["tfDir"]) / "recovery_plan.json")
                                  for e in manifest["entries"][4:]]
        path.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
        if mismatches or not audit["recoveryComplete"]:
            raise SystemExit("Recovery incomplete, preserved finals changed, or replayed-chunk evidence failed")
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
