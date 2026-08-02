# v0.1.6 Web UI + Python → MATLAB pipeline

## Goal

End-to-end receiver control **without** opening the MATLAB desktop or editing `.m` configs by hand:

1. Browser UI with **tabs**: 数据/IF · 捕获 · 跟踪 · 定位 · 显示  
2. Python HTTP server collects config JSON  
3. Auto-detect `matlab.exe` and run `runFromJsonConfig` via `-batch`  
4. After PVT, MATLAB `plotNavPost` (+ optional Baidu map); Python can re-open figures  

## Launch

```text
cd F:\matlab-GNSSsdr\BDS\B2a
python launch_b2a_ui.py
```

Opens `http://127.0.0.1:8787/`  

Optional:

```text
python launch_b2a_ui.py --port 8790 --no-browser
set B2A_MATLAB=C:\Program Files\MATLAB\R2024b\bin\matlab.exe
```

**Dependencies:** Python 3.9+ **stdlib only** (no pip packages). MATLAB on PATH or standard install path.

### UI notes (light research theme)

- 浅色科研风格；图标来自 `python/b2a_ui/icon/icon1.jpg`（复制到 `web/ui/assets/icon.jpg`）
- Tabs 覆盖几乎全部 `initSettings` 参数（数据 / PB / 捕获 / 跟踪 / FLL / KF / 闪烁 / 定位 / 显示）
- **Probe 探针**：仅读 IF 生成时域 + Welch 频谱 + 直方图 PNG，经 `/api/files/...` 嵌在页面中；入口 `core/runProbeIf.m`（基于 `probeData`）

## Layout

| Path | Role |
|------|------|
| `launch_b2a_ui.py` | Entry |
| `python/b2a_ui/server.py` | HTTP API + static UI |
| `python/b2a_ui/matlab_runner.py` | Find MATLAB, `-batch`, log pump |
| `web/ui/` | Frontend (HTML/CSS/JS + `schema.json`) |
| `config/ui_defaults.json` | Default form values |
| `core/runFromJsonConfig.m` | Full pipeline from JSON |
| `core/exportUiDefaults.m` | Optional: regenerate defaults from `initSettings` |

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | version + MATLAB path |
| GET | `/api/schema` | tab/field schema |
| GET | `/api/defaults` | default config |
| POST | `/api/run` | `{ "config": { ... } }` → `{ jobId, outDir }` |
| GET | `/api/job/<id>` | status, log tail, report |
| POST | `/api/open` | open figures / Baidu index |

## Output

```text
results/ui/<jobId>/
  ui_config.json
  matlab.log
  report.json
  pvt.nmea          (if enabled)
  figures/          (ENU, DOP, map, Baidu index.html)
  ui_results.mat
```

## Notes

- Nested keys in the form use dotted paths (`raim.enable`, `FLL.aidingEnable`).  
- `acqSatelliteList` accepts `24,38,39,41` or `1:60`.  
- Long runs stream into the log panel via job polling (~1.5 s).  
- Users never set MATLAB path in the UI if auto-detect succeeds.

## MATLAB Access Violation (0xC0000005) fix

R2024b may crash in `libmwi18n` at **startup** if the parent Python process
leaks `PYTHON*` / mixed locale into the child. The runner now:

1. Spawns MATLAB with a **minimal clean environment** (no `PYTHONHOME` / `PYTHONPATH`)
2. Prefers `matlab -batch`, then falls back to `-nosplash -nodesktop -wait -r …`
3. Optional preflight: `GET /api/matlab_probe` → `disp('B2A_OK')`

```text
# manual probe
python -c "import sys; sys.path.insert(0,'python'); from b2a_ui.matlab_runner import probe_matlab; print(probe_matlab())"
```

If probe still crashes: close other MATLAB instances; run once from a plain
`cmd.exe`: `matlab -batch "disp(1)"`; set `B2A_MATLAB` to `...\bin\matlab.exe`.
