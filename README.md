# BDS-3 B2a Software Receiver (Refactored)

Modernized layout of the CU Multi-GNSS B2a SDR with FLL-aided tracking,
NH/Weil state machine, pulse blanking, and restored **tracking → navigation** pipeline.

| Item | Path |
|------|------|
| **Source (read-only)** | `…/B2aFLLAided` |
| **This project** | `F:\matlab-GNSSsdr\BDS\B2a` |

## Quick start

### Web UI (recommended, no MATLAB desktop setup)

```text
cd F:\matlab-GNSSsdr\BDS\B2a
python launch_b2a_ui.py
```

Browser: http://127.0.0.1:8787 — tabs for IF / 捕获 / 跟踪 / 定位 / 显示, then **运行全流程**.  
MATLAB is auto-detected (`PATH` or install dir); optional `B2A_MATLAB` env. See [docs/web_ui_v016.md](docs/web_ui_v016.md).

### MATLAB CLI

```matlab
cd('F:\matlab-GNSSsdr\BDS\B2a')
setupPaths

% 1) Acquisition smoke (full sky or list)
smokeA = smoke_acquisition('fullSky', true);           % PRN 1..63
% or faster:
smokeA = smoke_acquisition('fullSky', false);          % default [24 38 39 41]

% 2) Tracking smoke (single strong SV, short)
smokeT = smoke_tracking('acqSatelliteList', smokeA.bestPrn, 'msToProcess', 5000);

% 3) Full pipeline (nav needs ≥24 s and ≥4 SVs with eph)
results = run_B2a('msToProcess', 60000, 'acqSatelliteList', [24 38 39 41]);
```

## Layout

See [docs/architecture.md](docs/architecture.md).

## 用户手册（推荐先读）

- **[中文用户手册：模块关系 · 捕获/跟踪/定位 · 可选算法](docs/user_manual_zh.md)** — 面向会一点 MATLAB 的新手，讲清数据流与如何打开 FLL/载波辅助/RAIM/加权/Web UI 等

## Design docs

- [Architecture](docs/architecture.md)
- [Acquisition](docs/acquisition_design.md)
- [Tracking](docs/tracking_design.md)
- [Navigation bridge](docs/navigation_design.md)
- [Module audit](docs/module_audit.md)
- [Optimization plan](docs/optimization_plan.md) (parallel + MEX — plan only)
- [Web UI v0.1.6](docs/web_ui_v016.md)

## Version

**v0.1.6** — Web UI + Python orchestrator: tabbed config (IF / acq / track / nav / plot), auto-detect MATLAB `-batch`, full pipeline, auto PVT plots & Baidu map. `python launch_b2a_ui.py` → http://127.0.0.1:8787

**v0.1.5** — Multi-segment TOW after REACQ (epoch LS if nSat≥4); optional elev/C/N0 WLS weights; NMEA GGA+GSV export; geobasemap streets-light + ENU/vel/DOP plots; Baidu CustomOverlay track UI; ENU jump filter (v>500 m/s).

**v0.1.4** — RAIM single/dual-SV FDE in PVT; Baidu Map opens via local HTTP (not `file://`) so basemap tiles load; offline WGS84→BD-09 fallback.

**v0.1.3** — post-PVT plots (ENU / sky / geoshow LLA) + Baidu Map JSAPI 4.0 trajectory web UI (WGS84→BD-09).

**v0.1.2** — carrier-aided code NCO (default on, instantaneous `carrFreq`, ±50 Hz code-domain clamp).

Branches: `master` (baseline), `mexBaseFast` (MEX path), `par-fast-matlab` (parfor + trackOneChannel).

### Post-PVT visualization

```matlab
% After navigation:
plotNavPost(navSolutions, settings);           % ENU/vel/DOP + geobasemap + Baidu UI
launchBaiduMapTrack(navSolutions, settings);   % map only (starts http://127.0.0.1:8765)
exportNmea(navSolutions, settings, 'trackResults', trackResults);  % GGA+GSV → pvt.nmea
% settings.plotNavPost=false;                  % silent (default true)
% settings.nmea.enable=false;                  % disable NMEA export
```

Put browser AK in `config/BaidumapKey.txt` (gitignored; see `BaidumapKey.example.txt`).  
Baidu console: enable JavaScript API; Referer whitelist include `127.0.0.1:*` or `*`.

## Version control

Iterate only under this tree. Commit after each successful smoke.

```text
git add -A
git commit -m "..."
```

Large IF files and `results/**/*.mat` are gitignored.
