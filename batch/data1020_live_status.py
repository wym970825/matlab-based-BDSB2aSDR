"""Read compact progress for the DATA1020 queue without loading MAT or IQ."""
import json
from pathlib import Path
import re
import sys


def read(path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}


root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "results/data1020/20261009_pb_tf_comparison"
manifest = read(root / "manifest.json")
completed, active = [], []
for entry in manifest.get("entries", []):
    folder = Path(entry["tfDir"])
    result = read(folder / "validation.json")
    if result.get("pipelineOk"):
        completed.append(entry["experimentNumber"])
        continue
    if not folder.exists():
        continue
    records = [read(p) for p in sorted(folder.glob("tracking_progress_prn*.json"))]
    records = [r for r in records if r]
    acquisition_processed = None
    if not records:
        try:
            log = (folder / "matlab.log").read_text(encoding="utf-8-sig", errors="replace")
            acquisition_processed = len(set(re.findall(r"PRN\((\d+)\) (?:acquisition failed|fine:)", log)))
        except OSError:
            pass
    active.append({
        "experiment": entry["experimentNumber"], "source": entry["sourceId"],
        "acquisitionPrnsProcessed": acquisition_processed,
        "fullPrns": [r["prn"] for r in records if r.get("status") == "complete"],
        "endedEarly": [{"prn": r["prn"], "seconds": round(r["completedMs"] / 1000, 3)}
                       for r in records if r.get("status") == "ended_early"],
        "running": [{"prn": r["prn"], "seconds": round(r["completedMs"] / 1000, 3),
                     "updatedAt": r.get("updatedAt")} for r in records if r.get("status") == "running"],
        "error": result.get("error", ""),
    })
print(json.dumps({"completedExperiments": completed, "active": active,
                  "queueComplete": (root / "tf_full_completion.json").exists()}, ensure_ascii=True))
