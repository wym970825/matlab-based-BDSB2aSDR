"""Locate MATLAB and run B2a pipeline without Engine or desktop dependencies.

IMPORTANT: Do NOT inherit the full Python process environment. R2024b can
Access-Violation crash in libmwi18n / microservices at startup when PYTHON*
vars or mixed locales leak in from the parent (common with python.org 3.x on
Windows). We spawn with a minimal clean env.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple


_LAUNCH_MODE_CACHE: dict[str, str] = {}


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def find_matlab() -> Optional[str]:
    """Return the newest MATLAB executable. Honors an explicit override."""
    env = os.environ.get("B2A_MATLAB") or os.environ.get("MATLAB_EXE")
    if env and Path(env).exists():
        return str(Path(env))

    candidates: List[Path] = []
    which = shutil.which("matlab")
    if which:
        candidates.append(Path(which))

    roots = []
    for base in (
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
    ):
        p = Path(base) / "MATLAB"
        if p.is_dir():
            roots.append(p)
    # Also support installations such as F:\MATLAB2026a.  Limit this to
    # the project drive root; no recursive disk scan is performed.
    project_drive = Path(project_root().anchor)
    if project_drive.is_dir():
        candidates.extend(project_drive.glob("MATLAB*/bin/matlab.exe"))
    for root in roots:
        candidates.extend(root.glob("R*/bin/matlab.exe"))

    unique: dict[str, Path] = {}
    for candidate in candidates:
        if candidate.is_file():
            unique[str(candidate.resolve()).lower()] = candidate.resolve()
    if not unique:
        return None
    newest = max(unique.values(), key=_matlab_release_sort_key)
    return str(newest)


def _matlab_release_sort_key(executable: Path) -> Tuple[int, int, str]:
    match = re.search(r"(?i)(20\d{2})([ab])", str(executable))
    if not match:
        return (0, 0, str(executable).lower())
    return (int(match.group(1)), 1 if match.group(2).lower() == "b" else 0,
            str(executable).lower())


def _launch_cache_key(matlab: str) -> str:
    return str(Path(matlab).resolve()).lower()


def _remember_launch_mode(matlab: str, mode: str) -> None:
    _LAUNCH_MODE_CACHE[_launch_cache_key(matlab)] = mode


def _needs_r2026a_startup_workaround(matlab: str) -> bool:
    return (sys.platform.startswith("win") and
            _matlab_release_sort_key(Path(matlab))[:2] >= (2026, 0))


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
    # Optional isolated MATLAB preferences.  This is useful for automation
    # and for diagnosing a damaged release-specific user preference tree
    # without renaming or overwriting the user's existing settings.
    pref_override = os.environ.get("B2A_MATLAB_PREFDIR", "").strip()
    if not pref_override and _needs_r2026a_startup_workaround(matlab_exe):
        pref_override = str(
            project_root() / "results" / "ui_runtime" / "r2026a_prefs"
        )
    if pref_override:
        pref_base = Path(pref_override).resolve()
        pref_base.mkdir(parents=True, exist_ok=True)
        # R2026a can crash after reusing a damaged preference tree.  Give
        # every receiver job/probe sequence a fresh child directory; all
        # fallback processes in that sequence deliberately share it.
        pref_path = pref_base / (
            f"session_{os.getpid()}_{threading.get_ident()}_{time.time_ns()}"
        )
        pref_path.mkdir(parents=True, exist_ok=True)
        env["MATLAB_PREFDIR"] = str(pref_path)
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
    """Return launch variants, preferring the last working mode per release."""
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
    preferred = (
        os.environ.get("B2A_MATLAB_LAUNCH_MODE", "").strip().lower()
        or _LAUNCH_MODE_CACHE.get(_launch_cache_key(matlab), "")
    )
    if not preferred and _needs_r2026a_startup_workaround(matlab):
        # On the tested R2026a Windows installation, project startup
        # through -batch crashes in the recent-artifacts service while the
        # guarded -r/-wait path is stable.
        preferred = "r_wait"
    if preferred:
        variants.sort(key=lambda item: 0 if item[0].lower() == preferred else 1)
    return variants


def probe_matlab(timeout_s: float = 120, launch_env: Optional[dict] = None) -> dict:
    """Quick start test using the same fallback modes as receiver jobs."""
    matlab = find_matlab()
    if not matlab:
        return {"ok": False, "error": "MATLAB not found", "matlab": None}
    statement = "fprintf('B2A_OK\\n');"
    attempts = []
    variants = _launch_variants(matlab, statement)
    if _needs_r2026a_startup_workaround(matlab):
        # A trivial batch start safely initializes R2026a's per-user
        # services; project statements still use r_wait afterward.
        variants.sort(key=lambda item: 0 if item[0] == "batch" else 1)
    for mode, cmd in variants:
        try:
            env = launch_env if launch_env is not None else _matlab_clean_env(matlab)
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
            attempts.append({"mode": mode, "exitCode": p.returncode,
                             "output": out[-2000:],
                             "prefDir": env.get("MATLAB_PREFDIR", "")})
            # Windows -r -wait can return no redirected output even though
            # MATLAB executed the guarded statement and exit(0).
            ok = p.returncode == 0 and (mode.startswith("r_") or "B2A_OK" in out)
            if ok:
                next_mode = "r_wait" if (
                    mode == "batch" and
                    _needs_r2026a_startup_workaround(matlab)
                ) else mode
                _remember_launch_mode(matlab, next_mode)
                return {"ok": True, "matlab": matlab,
                        "exitCode": p.returncode, "output": out[-2000:],
                        "mode": mode, "attempts": attempts}
        except Exception as exc:
            attempts.append({"mode": mode, "error": str(exc)})
    last = attempts[-1] if attempts else {}
    return {"ok": False, "matlab": matlab,
            "exitCode": last.get("exitCode"),
            "output": last.get("output", ""),
            "error": last.get("error", "MATLAB launch failed"),
            "mode": last.get("mode", ""), "attempts": attempts}


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
    # Keep one isolated preference tree for preflight and all fallbacks in
    # this job.  R2026a's trivial batch preflight initializes services that
    # the subsequent guarded r_wait project launch relies on.
    env = _matlab_clean_env(matlab)

    last_rc = None
    last_mode = ""
    combined_log: List[str] = []

    def _log(msg: str) -> None:
        combined_log.append(msg)
        if log_cb:
            log_cb(msg)

    _log(f"[matlab_runner] exe={matlab} entry={entry}\n")
    _log("[matlab_runner] using CLEAN environment (no PYTHON* inheritance)\n")

    # R2026a needs a trivial first launch before the stable project mode.
    # Older IF probes stay fast by skipping this preflight.
    skip_requested = os.environ.get(
        "B2A_SKIP_MATLAB_PROBE", ""
    ).strip().lower() in ("1", "true", "yes")
    skip_pf = skip_requested or (
        entry == "runProbeIf" and
        not _needs_r2026a_startup_workaround(matlab)
    )
    if not skip_pf:
        _log("[matlab_runner] preflight MATLAB launch…\n")
        probe = probe_matlab(timeout_s=180, launch_env=env)
        _log(f"[matlab_runner] preflight ok={probe.get('ok')} exit={probe.get('exitCode')} "
             f"err={probe.get('error')}\n")
        if not probe.get("ok"):
            _log(
                "[matlab_runner] WARNING: clean-env preflight failed. "
                "Will still try launch variants.\n"
            )
            if probe.get("output"):
                _log(probe["output"] + "\n")

    # Build this list after preflight so a working fallback discovered by
    # probe_matlab is used first for the actual receiver job.
    variants = _launch_variants(matlab, statement)
    for mode, cmd in variants:
        last_mode = mode
        _log(f"\n[matlab_runner] try mode={mode}\n$ {' '.join(cmd)}\n")
        if env.get("MATLAB_PREFDIR"):
            _log(f"[matlab_runner] isolated prefdir={env['MATLAB_PREFDIR']}\n")
        rc, text = _run_one(cmd, env=env, cwd=str(root), timeout_s=timeout_s, log_cb=_log)
        last_rc = rc
        # Access violation often 0xC0000005 = 3221225477 unsigned or -1073741819
        av = rc in (-1073741819, 3221225477, 0xC0000005) or (
            rc is not None and rc > 0xC0000000
        )
        report_path = out_dir / "report.json"
        if report_path.is_file() and (rc == 0 or report_path.stat().st_size > 10):
            if rc == 0:
                _remember_launch_mode(matlab, mode)
            break
        if rc == 0:
            _remember_launch_mode(matlab, mode)
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
                "(2) set B2A_MATLAB_LAUNCH_MODE=r_wait on Windows, "
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
    """Open the saved map or first navigation figure from the UI layout."""
    out_dir = Path(out_dir)
    fig = out_dir / "figures"
    nav = fig / "navResult"
    index = next((p for p in (fig / "index.html", nav / "index.html") if p.is_file()), None)

    if index is not None:
        serve_root = index.parent
        port = _serve_dir(serve_root)
        if port:
            webbrowser.open(f"http://127.0.0.1:{port}/{index.name}")
            return
        _open_path(index)
        return

    if fig.is_dir():
        for name in ("lla_geobasemap.png", "enu_displacement.png", "dop.png"):
            p = next((candidate for candidate in (nav / name, fig / name)
                      if candidate.is_file()), None)
            if p is not None:
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
