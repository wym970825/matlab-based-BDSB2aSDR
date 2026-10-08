"""Record final DATA1020 source provenance without altering startup evidence.

Formal output requires all six TF runs and saved-only figure postprocessing to
finish. --inspect computes a read-only preview while the queue is still active;
it never creates or overwrites final_source_manifest.json. This tool does not
commit, run MATLAB, read raw IQ, or hash large receiver MAT result files.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess


EXPECTED_IDS = {"beiqijiatai", "HUR_1", "HUR_2", "103330", "103801", "111407"}


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {}


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        while block := f.read(1024*1024):
            h.update(block)
    return h.hexdigest()


def normalized_files(value):
    return {k.replace("\\", "/"): v.lower() for k, v in value.items()}


def safe_project_file(project, relative):
    path = (project/relative).resolve()
    if not path.is_relative_to(project):
        raise ValueError(f"Source path leaves the repository: {relative}")
    return path


def git_bytes(project, *args):
    return subprocess.run(["git", "-C", str(project), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def git_snapshot(project):
    head = git_bytes(project, "rev-parse", "HEAD").decode("ascii").strip()
    branch = git_bytes(project, "branch", "--show-current").decode("utf-8").strip()
    status = git_bytes(project, "-c", "core.quotepath=false", "status", "--porcelain=v1", "-z").decode("utf-8").split("\0")
    records, i = [], 0
    while i < len(status):
        line = status[i]
        i += 1
        if not line:
            continue
        state = line[:2]
        row = {"status": state, "path": line[3:]}
        if "R" in state or "C" in state:
            row["originalPath"] = status[i]
            i += 1
        records.append(row)
    return {"head": head, "branch": branch, "worktreeClean": not records, "worktreeChanges": records,
            "note": "HEAD is the commit at manifest generation. SHA256 records describe actual working-tree bytes, including uncommitted files."}


def source_comparison(project, startup_files, pb_files):
    names = sorted(set(startup_files)|set(pb_files))
    current, missing, changes_start, changes_pb = {}, [], [], []
    for name in names:
        path = safe_project_file(project, name)
        if not path.is_file():
            missing.append(name)
            continue
        digest = sha256(path)
        current[name] = digest
        if startup_files.get(name) != digest:
            changes_start.append(name)
        if pb_files.get(name) != digest:
            changes_pb.append(name)
    same_set = set(startup_files) == set(pb_files)
    return {"sourceCount": len(names), "expectedSourceCount": 69,
            "startupSourceCount": len(startup_files), "pbSourceCount": len(pb_files),
            "sameSourceSet": same_set,
            "matchStartup": same_set and not missing and not changes_start,
            "matchPB": same_set and not missing and not changes_pb,
            "missingFiles": missing, "changedFromStartup": changes_start, "changedFromPB": changes_pb,
            "files": current,
            "scope": "The 69 source/MEX files from the established receiver manifest, including its existing batch driver; excludes raw IQ and result MAT files."}


def script_role(name):
    base = Path(name).stem.lower()
    if base.startswith(("export_", "compare_", "report_", "validate_", "verify_", "finalize_")):
        return "saved-result postprocessing or audit"
    if base.startswith(("analyze_", "cache_")) or base == "data1020_purple_orange":
        return "spectral analysis or map rendering support"
    if "finalize" in base or base.startswith("finish_"):
        return "saved-result finalization launcher"
    return "experiment orchestration or supporting utility"


def script_snapshot(project, startup_scripts):
    current_paths = {p.relative_to(project).as_posix() for p in (project/"batch").iterdir()
                     if p.is_file() and "data1020" in p.name.lower() and p.suffix.lower() in (".m", ".py", ".ps1")}
    names = sorted(current_paths|set(startup_scripts))
    current, changes, metadata = {}, [], {}
    for name in names:
        path = safe_project_file(project, name)
        digest = sha256(path) if path.is_file() else None
        before = startup_scripts.get(name)
        if digest is not None:
            current[name] = digest
            metadata[name] = {"role": script_role(name), "sizeBytes": path.stat().st_size,
                              "modifiedUtc": dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).isoformat()}
        if before != digest:
            kind = "added" if before is None else ("removed" if digest is None else "modified")
            changes.append({"path": name, "change": kind, "role": script_role(name),
                            "startupSha256": before, "finalSha256": digest})
    postprocessing = {name: digest for name, digest in current.items()
                      if script_role(name) in ("saved-result postprocessing or audit", "saved-result finalization launcher")}
    return {"files": current, "metadata": metadata, "postprocessingFiles": postprocessing,
            "startupFileCount": len(startup_scripts), "finalFileCount": len(current),
            "changesSinceStartup": changes,
            "scope": "Union of startup experimentScripts and current batch/*data1020*.m, *.py, or *.ps1 files. Added means absent from the startup script manifest, not a claim about earlier filesystem existence."}


def completion_status(root, manifest):
    entries = manifest.get("entries", [])
    stages = []
    for e in entries:
        path = Path(e["tfDir"])/"validation.json"
        val = read_json(path)
        stages.append({"experimentNumber": e["experimentNumber"], "sourceId": e["sourceId"],
                       "pipelineOk": val.get("pipelineOk") is True,
                       "allAcquiredTracked": val.get("allAcquiredTracked") is True,
                       "thresholdMatchesBaseline": val.get("thresholdMatchesBaseline") is True,
                       "validationPath": str(path)})
    queue = read_json(root/"tf_full_completion.json")
    post = read_json(root/"postprocessing_complete.json")
    ids = {e["sourceId"] for e in entries}
    all_runs = len(entries)==6 and ids==EXPECTED_IDS and all(
        s["pipelineOk"] and s["allAcquiredTracked"] and s["thresholdMatchesBaseline"] for s in stages)
    queue_ok = sorted(queue.get("indices", []))==list(range(1,7))
    post_ok = post.get("ok") is True and post.get("receiverRerun") is False
    return {"allSixTfRunsValidated": all_runs, "tfQueueComplete": queue_ok,
            "savedResultPostprocessingComplete": post_ok, "readyForFormalManifest": all_runs and queue_ok and post_ok,
            "runs": stages, "postprocessingCompletion": post}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--inspect", action="store_true", help="Print a read-only summary; never write the formal final manifest.")
    args = parser.parse_args()
    root = args.root.resolve()
    project = Path(__file__).resolve().parents[1]
    manifest_path = root/"manifest.json"
    start_path = root/"source_manifest.json"
    if not manifest_path.is_file() or not start_path.is_file():
        raise SystemExit("manifest.json and the immutable startup source_manifest.json are required")
    start_digest = sha256(start_path)
    start = read_json(start_path)
    manifest = read_json(manifest_path)
    pb_path = Path(manifest["baselineRoot"])/"source_hashes.json"
    pb = read_json(pb_path)
    receiver = source_comparison(project, normalized_files(start.get("files",{})), normalized_files(pb.get("files",{})))
    scripts = script_snapshot(project, normalized_files(start.get("experimentScripts",{})))
    readiness = completion_status(root, manifest)
    numerical_ok = receiver["sourceCount"]==69 and receiver["matchStartup"] and receiver["matchPB"]
    immutable_ok = sha256(start_path)==start_digest
    git = git_snapshot(project)
    state = "failed" if not numerical_ok or not immutable_ok else ("complete" if readiness["readyForFormalManifest"] else "pending")
    result = {"schemaVersion":1, "generatedUtc":dt.datetime.now(dt.timezone.utc).isoformat(),
              "ok": state=="complete", "state":state, "gitHead":git["head"], "git":git,
              "projectRoot":str(project), "outputRoot":str(root),
              "startupEvidence":{"path":str(start_path), "sha256":start_digest,
                                 "gitHead":start.get("gitHead"), "startedAtLocal":start.get("startedAtLocal"),
                                 "preservedWithoutModification":immutable_ok},
              "pbBaselineEvidence":{"path":str(pb_path), "sha256":sha256(pb_path) if pb_path.is_file() else None,
                                    "gitHead":pb.get("gitHead"), "note":pb.get("note", "")},
              "numericalSources":receiver, "batchSources":scripts, "completion":readiness,
              "method":{"rawIqRead":False, "resultMatRead":False, "matlabLaunched":False,
                        "gitModified":False, "startupManifestWritten":False,
                        "interpretation":"Source-byte equality proves the recorded files match the PB and TF-start manifests; it does not independently prove runtime execution or raw-data integrity. Saved receiver/filter/condition audits provide complementary evidence."}}
    summary = {"state":state, "inspectOnly":args.inspect, "gitHead":git["head"],
               "worktreeClean":git["worktreeClean"], "startupEvidencePreserved":immutable_ok,
               "numericalSourceCount":receiver["sourceCount"], "numericalMatchesPB":receiver["matchPB"],
               "numericalMatchesStartup":receiver["matchStartup"], "numericalChangedFromPB":receiver["changedFromPB"],
               "numericalChangedFromStartup":receiver["changedFromStartup"], "missingNumericalFiles":receiver["missingFiles"],
               "batchScriptCount":scripts["finalFileCount"], "batchChangesSinceStartup":scripts["changesSinceStartup"],
               "completedTfRuns":sum(s["pipelineOk"] for s in readiness["runs"]),
               "postprocessingComplete":readiness["savedResultPostprocessingComplete"], "formalManifestWritten":False}
    if not args.inspect and state=="complete":
        output = root/"final_source_manifest.json"
        temporary = root/"final_source_manifest.json.tmp"
        temporary.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
        temporary.replace(output)
        summary["formalManifestWritten"] = True
        summary["output"] = str(output)
    print(json.dumps(summary,ensure_ascii=True))
    if state=="failed": raise SystemExit(1)
    if not args.inspect and state!="complete": raise SystemExit(2)


if __name__=="__main__":
    main()
