"""Read compact DATA1020 progress without MAT/IQ reads or process inspection."""
import datetime as dt
import json
from pathlib import Path
import re
import sys


LOCAL_ZONE = dt.timezone(dt.timedelta(hours=8))


def read(path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}


def timestamp(value):
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=LOCAL_ZONE)
    except (TypeError, ValueError):
        return None


def file_updated(path):
    try:
        return dt.datetime.fromtimestamp(path.stat().st_mtime, LOCAL_ZONE)
    except OSError:
        return None


def tail(path, limit=131072):
    try:
        with path.open("rb") as f:
            f.seek(0, 2)
            offset = max(0, f.tell()-limit)
            f.seek(offset)
            data = f.read(limit).decode("utf-8-sig", errors="replace")
        return data.split("\n", 1)[-1] if offset else data
    except OSError:
        return ""


def acquisition_prns(log):
    return sorted({int(p) for p in re.findall(r"PRN\((\d+)\) (?:acquisition failed|fine:)", log)})


def fresh_file(path, started):
    updated = file_updated(path)
    return bool(started and updated and updated >= started)


def recovery_status(root, manifest, audit):
    marker = read(root/"recovery_current_stage.json")
    marker_source = "recovery_current_stage.json"
    if not marker:
        # The first prepare was launched manually before the serial runner.
        # Never use the pre-crash full-launch or per-run MATLAB log here.
        marker_source = "manual_prepare_fallback"
        marker = {"expression": "manual prepare for experiment 5", "log": "recovery_prepare_05.log",
                  "startedAtLocal": audit.get("createdUtc")}
    log_name = Path(marker.get("log", "")).name
    log_path = root/log_name
    started = timestamp(marker.get("startedAtLocal"))
    updated = file_updated(log_path) if log_name else None
    log = tail(log_path) if log_name else ""
    if started and updated and updated < started:
        log = ""  # A reused stage filename may still contain an earlier run.
    match = re.fullmatch(r"recovery_(prepare|track|finish)_(\d+)(?:_prn(\d+))?\.log", log_name)
    action, experiment, prn = (match[1], int(match[2]), int(match[3]) if match[3] else None) if match else (
        "finalize" if log_name == "finalize_launch.log" else "postprocess", None, None)
    entry = next((e for e in manifest.get("entries", []) if e["experimentNumber"] == experiment), {})
    folder = Path(entry["tfDir"]) if entry else None
    completion_evidence = []
    if folder:
        timing_name = f"recovery_timing_{action}" + (f"_{prn:02d}" if prn is not None else "") + ".json"
        if fresh_file(folder/timing_name, started) and read(folder/timing_name):
            completion_evidence.append(timing_name)
        if action == "prepare" and re.search(r"RECOVERY PREPARED\s+"+str(experiment).zfill(2)+r":", log):
            completion_evidence.append("RECOVERY PREPARED log marker")
        if action == "track" and prn is not None:
            name = f"recovery_prn{prn:02d}_complete.json"
            if fresh_file(folder/name, started) and read(folder/name):
                completion_evidence.append(name)
            if re.search(r"RECOVERY SKIP existing final PRN\s+0*"+str(prn)+r"\b", log):
                completion_evidence.append("existing final accepted by stage")
        if action == "finish" and fresh_file(folder/"validation.json", started) and read(folder/"validation.json").get("pipelineOk") is True:
            completion_evidence.append("validation.json pipelineOk")
    elif action == "finalize" and fresh_file(root/"postprocessing_complete.json", started):
        if read(root/"postprocessing_complete.json").get("ok") is True:
            completion_evidence.append("postprocessing_complete.json")
    failures = [line.strip() for line in log.splitlines() if re.match(
        r"\s*(?:Error using\b|Error in\b|Error:|MATLAB stage failed|ERROR:)", line)]
    runner_result = read(root/"recovery_runner_result.json") if fresh_file(root/"recovery_runner_result.json", started) else {}
    if runner_result.get("ok") is False:
        failures.append(str(runner_result.get("error", "Recovery runner failed")))
    state = "failed" if failures else ("completed" if completion_evidence else ("execution" if log else "waiting_for_log"))
    processed = acquisition_prns(log) if action == "prepare" else []
    return {
        "audit": "recovery_audit.json", "recoveryComplete": audit.get("recoveryComplete") is True,
        "execution": audit.get("execution", {}),
        "preservedFinalPrns": sorted(int(r["PRN"]) for r in audit.get("preservedFinals", [])),
        "restartWholeChannels": audit.get("restartWholeChannels", []),
        "runner": read(root/"recovery_runner_process.json"), "runnerResult": runner_result,
        "processLivenessChecked": False,
        "observationNote": "Execution means log activity was observed, not proof a MATLAB process is alive; old pre-crash heartbeats are excluded.",
        "currentStage": {
            "source": marker_source, "expression": marker.get("expression"), "log": log_name,
            "startedAtLocal": started.astimezone(LOCAL_ZONE).isoformat() if started else None,
            "startTimeBasis": "audit creation (manual prepare fallback)" if marker_source == "manual_prepare_fallback" else "stage marker",
            "experiment": experiment, "action": action, "prn": prn, "state": state,
            "logUpdatedAtLocal": updated.isoformat() if updated else None,
            "secondsSinceLogUpdate": round((dt.datetime.now(LOCAL_ZONE)-updated).total_seconds(), 1) if updated else None,
            "acquisitionPrnsProcessed": len(processed) if action == "prepare" else None,
            "acquisitionPrns": processed, "completionEvidence": completion_evidence,
            "lastLogLines": [line for line in log.splitlines() if line.strip()][-4:], "errors": failures[-4:],
        },
    }


def collect(root):
    manifest = read(root/"manifest.json")
    audit = read(root/"recovery_audit.json")
    recovery = recovery_status(root, manifest, audit) if audit else None
    stage = recovery["currentStage"] if recovery else {}
    started = timestamp(stage.get("startedAtLocal"))
    completed, active = [], []
    for entry in manifest.get("entries", []):
        folder = Path(entry["tfDir"])
        result = read(folder/"validation.json")
        if result.get("pipelineOk") is True:
            completed.append(entry["experimentNumber"])
            continue
        if not folder.exists() and not recovery:
            continue
        records = [read(p) for p in sorted(folder.glob("tracking_progress_prn*.json"))]
        records = [r for r in records if r]
        acquisition_processed = None
        if recovery:
            current = stage.get("experiment") == entry["experimentNumber"]
            records = [r for r in records if current and stage.get("action") == "track"
                       and started and timestamp(r.get("updatedAt"))
                       and timestamp(r.get("updatedAt")) >= started
                       and (stage.get("prn") is None or r.get("prn") == stage["prn"])]
            if current and stage.get("action") == "prepare":
                acquisition_processed = stage["acquisitionPrnsProcessed"]
        elif not records:
            log = tail(folder/"matlab.log")
            acquisition_processed = len(acquisition_prns(log)) if log else None
        running = records if not recovery or stage.get("state") == "execution" else []
        row = {
            "experiment": entry["experimentNumber"], "source": entry["sourceId"],
            "acquisitionPrnsProcessed": acquisition_processed,
            "fullPrns": [r["prn"] for r in records if r.get("status") == "complete"],
            "endedEarly": [{"prn": r["prn"], "seconds": round(r["completedMs"]/1000, 3)}
                           for r in records if r.get("status") == "ended_early"],
            "running": [{"prn": r["prn"], "seconds": round(r["completedMs"]/1000, 3),
                         "updatedAt": r.get("updatedAt")} for r in running if r.get("status") == "running"],
            "error": result.get("error", ""),
        }
        if recovery:
            row["recoveryStage"] = stage.get("action") if current else "queued"
            row["recoveryStageState"] = stage.get("state") if current else "waiting"
            row["savedFinalPrns"] = sorted(int(m[1]) for p in (folder/"temp").glob("Trk_Prn_*_final.mat")
                                            if (m := re.fullmatch(r"Trk_Prn_(\d+)_final\.mat", p.name)))
        active.append(row)
    result = {"completedExperiments": completed, "active": active,
              "queueComplete": len(completed) == 6 and (root/"tf_full_completion.json").is_file()}
    if recovery:
        result["recovery"] = recovery
    return result


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]/"results/data1020/20261009_pb_tf_comparison"
    print(json.dumps(collect(root), ensure_ascii=True))
