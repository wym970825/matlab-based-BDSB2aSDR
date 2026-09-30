# MATLAB R2026a compatibility

Tested on MATLAB `26.1.0.3203278 (R2026a)` at `F:\MATLAB2026a`.

## Result

- The existing `mexw64` correlator and pulse-blanker binaries load in
  R2026a.
- Both MEX sources rebuild with Microsoft Visual C++ 2022 in an isolated
  output directory. The Windows build no longer passes the obsolete
  `/arch:SSE2` switch; x64 MSVC already guarantees SSE2.
- The rebuilt correlator agrees with the MATLAB reference within the test
  tolerance and is about 10x faster for the deterministic benchmark.
- Classic figures, `uifigure`/`uiaxes`, and all four IF-probe images render
  successfully. R2026a web-backed UI components need a short render wait
  before `exportapp` in a no-desktop session.
- Five focused regression files pass (12 MATLAB unit tests plus the
  temporary-directory batch orchestration test).

The machine-specific R2026a `-batch` project launch crashes inside
`mwhomesessionmanager_impl` / `mwrecent_artifacts_service_impl`. The Web UI
therefore uses a trivial `-batch` preflight, prefers the guarded Windows
`-r -wait` mode for the project statement, and retains the other launch modes
as fallbacks.

## MCP configuration

The configured Codex server is named `matlab2026a` and starts a new desktop
session in this project:

```text
F:\Tools\MATLAB-MCP\matlab-mcp-server-windows-x64.exe
  --matlab-root F:\MATLAB2026a
  --matlab-session-mode new
  --matlab-display-mode desktop
  --initial-working-folder F:\matlab-GNSSsdr\BDS\B2a
  --initialize-matlab-on-startup true
  --disable-telemetry true
```

The older `matlab` MCP entry is unchanged. Restart Codex before expecting the
new `matlab2026a` tools to appear in a fresh tool inventory.

## Repeat the compatibility test

Run `tests/run_r2026a_compatibility.m` through the `matlab2026a` MCP server.
The function refuses to reuse an existing output path and writes its report,
synthetic IF input, rebuilt MEX binaries, and figures below a new directory:

```text
results/compat_r2026a/<timestamp>/compatibility_report.json
```

## Run the Web UI without touching user preferences

For R2026a the launcher automatically creates a new child settings directory
for every receiver job/probe launch sequence below
`results/ui_runtime/r2026a_prefs`. Existing R2026a preferences and receiver
data are not modified. `B2A_MATLAB_PREFDIR` can override that base:

```powershell
$env:B2A_MATLAB = 'F:\MATLAB2026a\bin\matlab.exe'
$env:B2A_MATLAB_PREFDIR = 'F:\matlab-GNSSsdr\BDS\B2a\results\ui_runtime\r2026a_prefs'
python launch_b2a_ui.py
```

Set `B2A_MATLAB_LAUNCH_MODE` to `batch` or `r_wait` only when a specific
override is needed.
