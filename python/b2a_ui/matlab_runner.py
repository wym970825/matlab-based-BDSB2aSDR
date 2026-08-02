"""Locate MATLAB and run B2a pipeline via -batch (no Engine / desktop needed).

IMPORTANT: Do NOT inherit the full Python process environment. R2024b can
Access-Violation crash in libmwi18n / microservices at startup when PYTHON*
vars or mixed locales leak in from the parent (common with python.org 3.x on
Windows). We spawn with a minimal clean env.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def find_matlab() -> Optional[str]:
    """Return matlab executable path. Honors B2A_MATLAB env override."""
    env = os.environ.get("B2A_MATLAB") or os.environ.get("MATLAB_EXE")
    if env and Path(env).exists():
        return str(Path(env))

    which = shutil.which("matlab")
    if which:
        return which

    roots = []
    for base in (
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
    ):
        p = Path(base) / "MATLAB"
        if p.is_dir():
            roots.append(p)
    for root in roots:
        cands = sorted(root.glob("R*/bin/matlab.exe"), reverse=True)
        for c in cands:
            if c.is_file():
                return str(c)
    return None


def _matlab_clean_env(matlab_exe: str) -> dict:
    """Minimal environment so MATLAB startup is not poisoned by Python."""
    keep_keys = [
        "SystemRoot", "SYSTEMROOT", "windir", "WINDIR",
        "SystemDrive", "SYSTEMDRIVE",
        "TEMP", "TMP", "TMPDIR",
        "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "HOME",
        "APPDATA", "LOCALAPPDATA",
        "USERNAME", "USERDOMAIN", "USERDOMAIN_ROAMINGPROFILE",
        "COMPUTERNAME", "LOGONSERVER",
        "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE",
        "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION",
        "OS", "PATHEXT", "ComSpec", "COMSPEC",
        "ProgramFiles", "ProgramFiles(x86)", "ProgramData",
        "CommonProgramFiles", "CommonProgramFiles(x86)",
        "PUBLIC", "ALLUSERSPROFILE",
        "DriverData",
    ]
    env: dict = {}
    for k in keep_keys:
        if k in os.environ and os.environ[k]:
            env[k] = os.environ[k]

    # Explicitly drop anything Python-related if present in parent
    # (we never copy them, but document intent)
    for k in list(os.environ.keys()):
        ku = k.upper()
        if ku.startswith("PYTHON") or ku.startswith("CONDA") or ku in (
            "VIRTUAL_ENV", "PIP_USER", "UV_PROJECT",
        ):
            pass  # not copied

    matlab_bin = str(Path(matlab_exe).resolve().parent)
    win = env.get("SystemRoot") or env.get("SYSTEMROOT") or r"C:\Windows"
    system32 = str(Path(win) / "System32")
    # MATLAB first, then system paths only
    path_parts = [
        matlab_bin,
        system32,
        str(Path(win)),
        str(Path(win) / "System32" / "Wbem"),
        str(Path(win) / "System32" / "WindowsPowerShell" / "v1.0"),
    ]
    env["PATH"] = os.pathsep.join(path_parts)

    # Stable locale — mixed Python UTF-8 + CN Windows has crashed libmwi18n
    env["LANG"] = "en_US"
    env["LC_ALL"] = "en_US"
    env["LC_CTYPE"] = "en_US"
    # Prefer no desktop / no browser splash
    env["MW_MATLAB_FORCE_NO_DESKTOP"] = "1"
    # Avoid MATLAB trying to bootstrap external Python (Engine / pyenv)
    env["MW_PY_DISABLE_AUTO_INSTALL"] = "1"
    return env


def _build_matlab_statement(root: Path, cfg_path: Path, entry: str = "runFromJsonConfig") -> str:
    root_m = str(root).replace("\\", "/")
    cfg_m = str(cfg_path).replace("\\", "/")
    if entry not in ("runFromJsonConfig", "runProbeIf"):
        entry = "runFromJsonConfig"
    # Single-line, no newlines (safer for -batch / -r)
    return (
        f"cd('{root_m}');"
        f"setupPaths;"
        f"{entry}('{cfg_m}');"
    )


def _launch_variants(matlab: str, statement: str) -> List[Tuple[str, List[str]]]:
    """Ordered command variants. Prefer clean -batch, then -r -wait fallbacks."""
    variants: List[Tuple[str, List[str]]] = []
    # 1) Official non-interactive batch (R2019a+)
    variants.append(("batch", [matlab, "-batch", statement]))
    # 2) nodesktop + -r + -wait (Windows classic)
    if sys.platform.startswith("win"):
        r_stmt = (
            "try," + statement +
            "catch ME,fprintf(2,'%s\\n',getReport(ME,'extended','hyperlinks','off'));"
            "exit(1);end;exit(0);"
        )
        variants.append((
            "r_wait",
            [matlab, "-nosplash", "-nodesktop", "-wait", "-r", r_stmt],
        ))
        # 3) via cmd with env scrub in shell
        variants.append((
            "cmd_batch",
            [
                "cmd.exe", "/d", "/c",
                f'set PYTHONHOME=& set PYTHONPATH=& set PYTHONUTF8=& '
                f'"{matlab}" -batch "{statement}"',
            ],
        ))
    else:
        r_stmt = (
            "try," + statement +
            "catch ME,fprintf(2,'%s\\n',getReport(ME,'extended','hyperlinks','off'));"
            "exit(1);end;exit(0);"
        )
        variants.append((
            "r_nodesktop",
            [matlab, "-nosplash", "-nodesktop", "-r", r_stmt],
        ))
    return variants


def probe_matlab(timeout_s: float = 120) -> dict:
    """Quick start test: matlab -batch \"disp('B2A_OK')\" with clean env."""
    matlab = find_matlab()
    if not matlab:
        return {"ok": False, "error": "MATLAB not found", "matlab": None}
    env = _matlab_clean_env(matlab)
    cmd = [matlab, "-batch", "fprintf('B2A_OK\\n');"]
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            timeout=timeout_s,
            cwd=str(Path(matlab).parent),
        )
        out = (p.stdout or "") + (p.stderr or "")
        ok = p.returncode == 0 and "B2A_OK" in out
        return {
            "ok": ok,
            "matlab": matlab,
            "exitCode": p.returncode,
            "output": out[-2000:],
            "mode": "clean_env_batch",
        }
    except Exception as e:
        return {"ok": False, "matlab": matlab, "error": str(e)}


def run_probe(
    config: dict,
    out_dir: Path,
    log_cb: Optional[Callable[[str], None]] = None,
    timeout_s: Optional[float] = 600,
) -> dict:
    """IF probe only (time + spectrum PNG). Calls runProbeIf via MATLAB."""
    return _run_matlab_job(
        config, out_dir, entry="runProbeIf", log_cb=log_cb, timeout_s=timeout_s
    )


def run_pipeline(
    config: dict,
    out_dir: Path,
    log_cb: Optional[Callable[[str], None]] = None,
    timeout_s: Optional[float] = None,
) -> dict:
    """Write config JSON, invoke MATLAB with clean env, return report dict."""
    return _run_matlab_job(
        config, out_dir, entry="runFromJsonConfig", log_cb=log_cb, timeout_s=timeout_s
    )


def _run_matlab_job(
    config: dict,
    out_dir: Path,
    entry: str = "runFromJsonConfig",
    log_cb: Optional[Callable[[str], None]] = None,
    timeout_s: Optional[float] = None,
) -> dict:
    """Shared launcher for pipeline / probe."""
    root = project_root()
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    cfg_path = out_dir / "ui_config.json"
    config = dict(config)
    config["outDir"] = str(out_dir).replace("\\", "/")
    config["tag"] = config.get("tag") or time.strftime("%y%m%d_%H%M%S")
    cfg_path.write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")

    matlab = find_matlab()
    if not matlab:
        return {
            "ok": False,
            "stage": "no_matlab",
            "error": (
                "MATLAB executable not found. Install MATLAB or set env "
                "B2A_MATLAB to full path of matlab.exe"
            ),
            "outDir": str(out_dir),
        }

    statement = _build_matlab_statement(root, cfg_path, entry=entry)
    log_path = out_dir / "matlab.log"
    env = _matlab_clean_env(matlab)
    variants = _launch_variants(matlab, statement)

    last_rc = None
    last_mode = ""
    combined_log: List[str] = []

    def _log(msg: str) -> None:
        combined_log.append(msg)
        if log_cb:
            log_cb(msg)

    _log(f"[matlab_runner] exe={matlab} entry={entry}\n")
    _log("[matlab_runner] using CLEAN environment (no PYTHON* inheritance)\n")

    # Optional MATLAB start preflight (skip for IF probe job — already short)
    skip_pf = (
        entry == "runProbeIf"
        or os.environ.get("B2A_SKIP_MATLAB_PROBE", "").strip().lower() in ("1", "true", "yes")
    )
    if not skip_pf:
        _log("[matlab_runner] preflight matlab -batch…\n")
        probe = probe_matlab(timeout_s=180)
        _log(f"[matlab_runner] preflight ok={probe.get('ok')} exit={probe.get('exitCode')} "
             f"err={probe.get('error')}\n")
        if not probe.get("ok"):
            _log(
                "[matlab_runner] WARNING: clean-env preflight failed. "
                "Will still try launch variants.\n"
            )
            if probe.get("output"):
                _log(probe["output"] + "\n")

    for mode, cmd in variants:
        last_mode = mode
        _log(f"\n[matlab_runner] try mode={mode}\n$ {' '.join(cmd)}\n")
        rc, text = _run_one(cmd, env=env, cwd=str(root), timeout_s=timeout_s, log_cb=_log)
        last_rc = rc
        # Access violation often 0xC0000005 = 3221225477 unsigned or -1073741819
        av = rc in (-1073741819, 3221225477, 0xC0000005) or (
            rc is not None and rc > 0xC0000000
        )
        report_path = out_dir / "report.json"
        if report_path.is_file() and (rc == 0 or report_path.stat().st_size > 10):
            break
        if rc == 0:
            break
        if av:
            _log(
                f"[matlab_runner] mode={mode} Access Violation (exit={rc}). "
                "Trying next launch mode…\n"
            )
            continue
        # non-AV failure: still try next mode if no report
        if not report_path.is_file():
            _log(f"[matlab_runner] mode={mode} exit={rc}, no report.json — try next\n")
            continue
        break

    # Persist full log
    log_path.write_text("".join(combined_log), encoding="utf-8", errors="replace")

    report_path = out_dir / "report.json"
    if report_path.is_file():
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except Exception as e:
            report = {
                "ok": last_rc == 0,
                "stage": "report_parse_error",
                "error": str(e),
                "outDir": str(out_dir),
            }
    else:
        hint = ""
        if last_rc in (-1073741819, 3221225477) or (
            last_rc is not None and isinstance(last_rc, int) and last_rc < 0
        ):
            hint = (
                " MATLAB Access Violation during startup is often caused by "
                "inherited Python env; runner already uses clean env. Try: "
                "(1) close other MATLAB instances, "
                "(2) run once from desktop: matlab -batch \"disp(1)\", "
                "(3) set B2A_MATLAB to matlab.exe under bin\\, "
                "(4) delete corrupt prefs if needed."
            )
        report = {
            "ok": False,
            "stage": "no_report",
            "error": f"MATLAB exit={last_rc} mode={last_mode}; see matlab.log.{hint}",
            "outDir": str(out_dir),
        }
    report["log"] = str(log_path)
    report["matlab"] = matlab
    report["exitCode"] = last_rc
    report["launchMode"] = last_mode
    return report


def _run_one(
    cmd: Sequence[str],
    env: dict,
    cwd: str,
    timeout_s: Optional[float],
    log_cb: Callable[[str], None],
) -> Tuple[Optional[int], str]:
    chunks: List[str] = []
    try:
        # Windows: avoid CREATE_NO_WINDOW — can contribute to early crashes
        kwargs = dict(
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            cwd=cwd,
            env=env,
            bufsize=1,
        )
        proc = subprocess.Popen(list(cmd), **kwargs)

        def _pump():
            assert proc.stdout is not None
            for line in proc.stdout:
                chunks.append(line)
                log_cb(line)

        t = threading.Thread(target=_pump, daemon=True)
        t.start()
        try:
            proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            proc.kill()
            log_cb("\n[timeout] MATLAB process killed\n")
            t.join(timeout=5)
            return -9, "".join(chunks)
        t.join(timeout=5)
        return proc.returncode, "".join(chunks)
    except Exception as e:
        log_cb(f"\n[spawn error] {e}\n")
        return -1, str(e)


_http_servers: dict[int, tuple[object, Path]] = {}


def open_results(out_dir: Path) -> None:
    """Open Baidu map index via localhost if present, else figures folder / PNGs."""
    out_dir = Path(out_dir)
    fig = out_dir / "figures"
    index = fig / "index.html"

    if index.is_file():
        port = _serve_dir(fig)
        if port:
            webbrowser.open(f"http://127.0.0.1:{port}/index.html")
            return
        _open_path(index)
        return

    if fig.is_dir():
        for name in ("lla_geobasemap.png", "enu_displacement.png", "dop.png"):
            p = fig / name
            if p.is_file():
                _open_path(p)
                break
        else:
            _open_path(fig)
        return

    nmea = out_dir / "pvt.nmea"
    if nmea.is_file():
        _open_path(nmea)
        return
    _open_path(out_dir)


def _serve_dir(directory: Path) -> Optional[int]:
    import http.server
    import socketserver

    directory = directory.resolve()
    for port in range(8765, 8780):
        if port in _http_servers:
            _, served_dir = _http_servers[port]
            if served_dir == directory:
                return port
            continue
        try:
            class _Quiet(http.server.SimpleHTTPRequestHandler):
                def __init__(self, *a, **k):
                    super().__init__(*a, directory=str(directory), **k)

                def log_message(self, *args):  # noqa: ANN001
                    return

            httpd = socketserver.ThreadingTCPServer(("127.0.0.1", port), _Quiet)
            httpd.allow_reuse_address = True
            t = threading.Thread(target=httpd.serve_forever, daemon=True)
            t.start()
            _http_servers[port] = (httpd, directory)
            return port
        except OSError:
            continue
    return None


def _open_path(path: Path) -> None:
    path = Path(path)
    try:
        if sys.platform.startswith("win"):
            os.startfile(str(path))  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        else:
            subprocess.Popen(["xdg-open", str(path)])
    except Exception:
        webbrowser.open(path.as_uri())
