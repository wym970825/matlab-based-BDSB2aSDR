"""
B2a Web UI server (stdlib only).

  python -m b2a_ui.server
  python launch_b2a_ui.py

Serves schema + static UI, runs MATLAB via -batch, streams log, returns report.
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
import traceback
import uuid
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import urlparse, parse_qs

# Allow `python server.py` from this folder
_HERE = Path(__file__).resolve().parent
if str(_HERE.parent) not in sys.path:
    sys.path.insert(0, str(_HERE.parent))

from b2a_ui.matlab_runner import (  # noqa: E402
    find_matlab,
    open_results,
    probe_matlab,
    project_root,
    run_pipeline,
    run_probe,
)

ROOT = project_root()
UI_DIR = ROOT / "web" / "ui"
ICON_DIR = ROOT / "python" / "b2a_ui" / "icon"
SCHEMA_PATH = UI_DIR / "schema.json"
DEFAULTS_PATH = ROOT / "config" / "ui_defaults.json"
JOBS_DIR = ROOT / "results" / "ui"


class JobStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.jobs: Dict[str, Dict[str, Any]] = {}

    def create(self) -> str:
        jid = time.strftime("%y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
        with self._lock:
            self.jobs[jid] = {
                "id": jid,
                "status": "queued",
                "log": "",
                "report": None,
                "outDir": str(JOBS_DIR / jid),
                "started": time.time(),
            }
        return jid

    def append_log(self, jid: str, text: str) -> None:
        with self._lock:
            if jid in self.jobs:
                self.jobs[jid]["log"] += text
                # cap log size ~2MB
                if len(self.jobs[jid]["log"]) > 2_000_000:
                    self.jobs[jid]["log"] = self.jobs[jid]["log"][-1_500_000:]

    def update(self, jid: str, **kw: Any) -> None:
        with self._lock:
            if jid in self.jobs:
                self.jobs[jid].update(kw)

    def get(self, jid: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            j = self.jobs.get(jid)
            return dict(j) if j else None


STORE = JobStore()


def load_defaults() -> dict:
    if DEFAULTS_PATH.is_file():
        try:
            return json.loads(DEFAULTS_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    # Fallback minimal defaults
    return {
        "msToProcess": 60000,
        "numberOfChannels": 12,
        "filePath": r"F:\Data\DME_BDSB2a\Experiment\2022BJ\DATA1020",
        "fileName": "300sData_@111407_221020@_1176450000_20000000_0_20000000_ZeroIF.bin",
        "samplingFreq": 20000000,
        "IF": 0,
        "dataType": "int16",
        "fileType": 2,
        "EnablePB": True,
        "skipAcquisition": False,
        "acqSatelliteList": "24,38,39,41",
        "acqSearchBand": 5000,
        "acqThreshold": 2,
        "acqStep": 125,
        "fineNoncoh": 5,
        "dllNoiseBandwidth_pull": 10,
        "dllNoiseBandwidth_stab": 2,
        "pllNoiseBandwidth_pull": 50,
        "pllNoiseBandwidth_stab": 30,
        "filter_pullinMS": 2000,
        "trackInit_MS": 3000,
        "carrierAidCode": True,
        "carrierAidCodeMaxHz": 50,
        "TrkCN0Th": 25,
        "CNo_Th": 30,
        "FLL": {"enable": True, "aidingEnable": True},
        "REACQ_max": 5,
        "useParfor": True,
        "parMaxWorkers": 4,
        "plotTracking": False,
        "doNavigation": True,
        "navSolPeriod": 500,
        "elevationMask": 5,
        "useTropCorr": True,
        "raim": {
            "enable": True,
            "enableFde1": True,
            "enableFde2": True,
            "maxRmsM": 80,
            "maxResM": 200,
        },
        "lsWeight": {"enableElev": False, "enableCno": False, "wMin": 0.05},
        "navTrackMaxSpeedMps": 500,
        "nmea": {"enable": True, "talkerId": "GB"},
        "doNmea": True,
        "doPlot": True,
        "plotNavPost": True,
        "plotBaiduMap": True,
        "doBaiduMap": True,
    }


def set_nested(cfg: dict, dotted: str, value: Any) -> None:
    parts = dotted.split(".")
    cur = cfg
    for p in parts[:-1]:
        if p not in cur or not isinstance(cur[p], dict):
            cur[p] = {}
        cur = cur[p]
    cur[parts[-1]] = value


def normalize_config(cfg: dict) -> dict:
    """Coerce UI form values to JSON types MATLAB expects."""
    out = json.loads(json.dumps(cfg))  # deep copy

    def as_bool(v):
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return v != 0
        if isinstance(v, str):
            return v.strip().lower() in ("1", "true", "yes", "on")
        return bool(v)

    def as_num(v):
        if isinstance(v, (int, float)):
            return v
        if isinstance(v, str) and v.strip() != "":
            try:
                if "." in v or "e" in v.lower():
                    return float(v)
                return int(v)
            except ValueError:
                return v
        return v

    bool_keys = [
        "EnablePB", "skipAcquisition", "carrierAidCode", "useParfor",
        "plotTracking", "doNavigation", "useTropCorr", "doNmea", "doPlot",
        "plotNavPost", "plotBaiduMap", "doBaiduMap", "plotNavLegacy",
    ]
    for k in bool_keys:
        if k in out:
            out[k] = as_bool(out[k])

    for nest, keys in (
        ("FLL", ["enable", "aidingEnable", "useBpskFold"]),
        ("raim", ["enable", "enableFde1", "enableFde2", "alwaysSearch"]),
        ("lsWeight", ["enableElev", "enableCno"]),
        ("nmea", ["enable"]),
        ("KF", ["enable", "enableFeedback"]),
    ):
        if nest in out and isinstance(out[nest], dict):
            for k in keys:
                if k in out[nest]:
                    out[nest][k] = as_bool(out[nest][k])

    num_keys = [
        "msToProcess", "samplingFreq", "IF", "fileType", "numberOfChannels",
        "acqSearchBand", "acqThreshold", "acqStep", "fineNoncoh",
        "dllNoiseBandwidth_pull", "dllNoiseBandwidth_stab",
        "pllNoiseBandwidth_pull", "pllNoiseBandwidth_stab",
        "filter_pullinMS", "trackInit_MS", "carrierAidCodeMaxHz",
        "TrkCN0Th", "CNo_Th", "REACQ_max", "parMaxWorkers",
        "navSolPeriod", "elevationMask", "navTrackMaxSpeedMps",
    ]
    for k in num_keys:
        if k in out:
            out[k] = as_num(out[k])

    if "acqSatelliteList" in out and isinstance(out["acqSatelliteList"], list):
        out["acqSatelliteList"] = ",".join(str(int(x)) for x in out["acqSatelliteList"])

    return out


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(UI_DIR), **kwargs)

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[http] " + (fmt % args) + "\n")

    def _json(self, code: int, obj: Any) -> None:
        body = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        u = urlparse(self.path)
        path = u.path

        if path in ("/", "/index.html"):
            return SimpleHTTPRequestHandler.do_GET(self)

        if path.rstrip("/") == "/api/health" or path == "/api/health":
            matlab = find_matlab()
            return self._json(200, {
                "ok": True,
                "projectRoot": str(ROOT),
                "matlab": matlab,
                "matlabFound": bool(matlab),
                "version": _version(),
                "endpoints": {
                    "POST": ["/api/run", "/api/probe", "/api/open"],
                    "GET": ["/api/health", "/api/schema", "/api/defaults",
                            "/api/job/<id>", "/api/files/...", "/api/matlab_probe"],
                },
                "note": "MATLAB is launched with a clean env (no PYTHON* inheritance)",
            })

        if path == "/api/matlab_probe":
            # May take ~30–90s cold start
            result = probe_matlab(timeout_s=180)
            return self._json(200, result)

        if path == "/api/schema":
            if not SCHEMA_PATH.is_file():
                return self._json(404, {"error": "schema.json missing"})
            data = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
            return self._json(200, data)

        if path == "/api/defaults":
            return self._json(200, load_defaults())

        if path.startswith("/api/job/"):
            jid = path.split("/api/job/", 1)[1].strip("/")
            if not jid:
                return self._json(400, {"error": "missing job id"})
            job = STORE.get(jid)
            if not job:
                # try disk
                disk = JOBS_DIR / jid / "report.json"
                if disk.is_file():
                    try:
                        rep = json.loads(disk.read_text(encoding="utf-8"))
                        return self._json(200, {
                            "id": jid,
                            "status": "done" if rep.get("ok") else "failed",
                            "report": rep,
                            "log": _tail_log(JOBS_DIR / jid / "matlab.log"),
                            "outDir": str(JOBS_DIR / jid),
                        })
                    except Exception as e:
                        return self._json(500, {"error": str(e)})
                return self._json(404, {"error": "job not found"})
            # don't send full multi-MB log every time unless ?full=1
            qs = parse_qs(u.query)
            full = qs.get("full", ["0"])[0] == "1"
            payload = dict(job)
            if not full and len(payload.get("log") or "") > 80_000:
                payload["log"] = payload["log"][-80_000:]
                payload["logTruncated"] = True
            return self._json(200, payload)

        if path.startswith("/api/files/"):
            # serve result files under results/ui/
            rel = path[len("/api/files/"):]
            fp = (JOBS_DIR / rel).resolve()
            if not str(fp).startswith(str(JOBS_DIR.resolve())):
                return self._json(403, {"error": "forbidden"})
            if not fp.is_file():
                self.send_error(404)
                return
            data = fp.read_bytes()
            ctype = "application/octet-stream"
            if fp.suffix.lower() in (".png",):
                ctype = "image/png"
            elif fp.suffix.lower() in (".jpg", ".jpeg"):
                ctype = "image/jpeg"
            elif fp.suffix == ".html":
                ctype = "text/html; charset=utf-8"
            elif fp.suffix == ".json":
                ctype = "application/json"
            elif fp.suffix == ".nmea" or fp.suffix == ".log":
                ctype = "text/plain; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return

        if path.startswith("/icon/"):
            name = path[len("/icon/"):]
            fp = (ICON_DIR / name).resolve()
            if not str(fp).startswith(str(ICON_DIR.resolve())) or not fp.is_file():
                self.send_error(404)
                return
            data = fp.read_bytes()
            ctype = "image/jpeg" if fp.suffix.lower() in (".jpg", ".jpeg") else "image/png"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # static from web/ui
        return SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self) -> None:  # noqa: N802
        u = urlparse(self.path)
        path = (u.path or "/").rstrip("/") or "/"
        # Accept both /api/probe and /api/probe/

        if path == "/api/run":
            try:
                body = self._read_json()
            except Exception as e:
                return self._json(400, {"error": f"bad json: {e}"})
            cfg = normalize_config(body.get("config") or body)
            jid = STORE.create()
            out_dir = Path(STORE.get(jid)["outDir"])
            STORE.update(jid, status="running", kind="pipeline")

            def worker():
                def log_cb(line: str):
                    STORE.append_log(jid, line)

                try:
                    report = run_pipeline(cfg, out_dir, log_cb=log_cb)
                    status = "done" if report.get("ok") else "failed"
                    STORE.update(jid, status=status, report=report)
                    if report.get("ok") and cfg.get("doPlot", True):
                        try:
                            open_results(out_dir)
                        except Exception as e:
                            STORE.append_log(jid, f"\n[open_results] {e}\n")
                except Exception as e:
                    STORE.append_log(jid, "\n" + traceback.format_exc())
                    STORE.update(
                        jid,
                        status="failed",
                        report={"ok": False, "error": str(e), "outDir": str(out_dir)},
                    )

            threading.Thread(target=worker, daemon=True).start()
            return self._json(200, {"jobId": jid, "outDir": str(out_dir), "kind": "pipeline"})

        if path == "/api/probe":
            try:
                body = self._read_json()
            except Exception as e:
                return self._json(400, {"error": f"bad json: {e}"})
            cfg = normalize_config(body.get("config") or body)
            jid = "probe_" + time.strftime("%y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
            out_dir = JOBS_DIR / jid
            out_dir.mkdir(parents=True, exist_ok=True)
            with STORE._lock:
                STORE.jobs[jid] = {
                    "id": jid,
                    "status": "running",
                    "kind": "probe",
                    "log": "",
                    "report": None,
                    "outDir": str(out_dir),
                    "started": time.time(),
                }

            def worker_probe():
                def log_cb(line: str):
                    STORE.append_log(jid, line)

                try:
                    report = run_probe(cfg, out_dir, log_cb=log_cb, timeout_s=600)
                    # Attach absolute image URLs for UI
                    imgs = {}
                    if report.get("images"):
                        for k, rel in report["images"].items():
                            if rel:
                                imgs[k] = f"/api/files/{jid}/{rel}".replace("\\", "/")
                    elif (out_dir / "probe").is_dir():
                        for name, key in (
                            ("probe_spectrum.png", "spectrum"),
                            ("probe_time.png", "time"),
                            ("probe_hist.png", "hist"),
                            ("probe_pb_debug.png", "pbDebug"),
                        ):
                            if (out_dir / "probe" / name).is_file():
                                imgs[key] = f"/api/files/{jid}/probe/{name}"
                    # Always fill pbDebug URL if file exists
                    pb_png = out_dir / "probe" / "probe_pb_debug.png"
                    if pb_png.is_file() and "pbDebug" not in imgs:
                        imgs["pbDebug"] = f"/api/files/{jid}/probe/probe_pb_debug.png"
                    report["imageUrls"] = imgs
                    status = "done" if report.get("ok") else "failed"
                    STORE.update(jid, status=status, report=report)
                except Exception as e:
                    STORE.append_log(jid, "\n" + traceback.format_exc())
                    STORE.update(
                        jid,
                        status="failed",
                        report={"ok": False, "error": str(e), "outDir": str(out_dir)},
                    )

            threading.Thread(target=worker_probe, daemon=True).start()
            return self._json(200, {"jobId": jid, "outDir": str(out_dir), "kind": "probe"})

        if path == "/api/open":
            body = self._read_json()
            out = body.get("outDir") or ""
            if out:
                open_results(Path(out))
            return self._json(200, {"ok": True})

        return self._json(404, {
            "error": "unknown endpoint",
            "path": path,
            "hint": "POST /api/run | /api/probe | /api/open — restart: python launch_b2a_ui.py",
        })


def _version() -> str:
    vp = ROOT / "VERSION"
    if vp.is_file():
        return vp.read_text(encoding="utf-8").strip()
    return "0.1.6"


def _tail_log(path: Path, n: int = 20000) -> str:
    if not path.is_file():
        return ""
    data = path.read_text(encoding="utf-8", errors="replace")
    return data[-n:]


def main(host: str = "127.0.0.1", port: int = 8787, open_browser: bool = True) -> None:
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    UI_DIR.mkdir(parents=True, exist_ok=True)

    # Ensure defaults exist (optional MATLAB dump later)
    if not DEFAULTS_PATH.is_file():
        DEFAULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
        DEFAULTS_PATH.write_text(
            json.dumps(load_defaults(), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    httpd = ThreadingHTTPServer((host, port), Handler)
    url = f"http://{host}:{port}/"
    matlab = find_matlab()
    print("=" * 60)
    print(f" BDS B2a Web UI  v{_version()}")
    print(f" UI:     {url}")
    print(f" Root:   {ROOT}")
    print(f" MATLAB: {matlab or '(not found — set B2A_MATLAB)'}")
    print("=" * 60)
    if open_browser:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        httpd.shutdown()


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="B2a Web UI server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    main(host=args.host, port=args.port, open_browser=not args.no_browser)
