# Branch `mexBaseFast` — P0 / P1 / P2

## Goals
| ID | Target | Change |
|----|--------|--------|
| P0 | `TrackResults2.update` | `writeTick` / `writeCNo` / `writeS4`; switch-based `update` (no `isprop`) |
| P1 | `pulseBlanker.mitigate` | Single-pass power; correct Ppre/Ppost; optional `pulseBlank_core_mex` |
| P2 | Correlator kernel | `correlateB2aMs.m` + `correlateB2aMs_mex` C MEX |

## Build MEX
```matlab
cd('F:\matlab-GNSSsdr\BDS\B2a')
setupPaths
build_mex   % in mex/
```

Requires a supported C compiler (`mex -setup C`).

## Smoke
```matlab
setupPaths
build_mex
smoke = smoke_tracking('acqSatelliteList',41,'msToProcess',5000,'doQuickPlot',false);
rankT = profile_track_hotspots('msToProcess',8000,'acqSatelliteList',41);
```

## Benchmark (PRN 41, same IF file)

| Metric | master (before) | mexBaseFast |
|--------|----------------:|------------:|
| 5 s track wall | 26.2 s | **14.4 s** (~1.8×) |
| 8 s profile wall | 33.8 s | **22.1 s** (~1.5×) |
| `TrackResults2.update` | 10.8 s | **writeTick 0.22 s** |
| `isprop` | 4.0 s | gone from top |
| blanker | 3.7 s | **1.1 s** (MEX 0.4 s inside) |
| correlator | (inline) | **MEX ~5.3 s** (explicit) |
| mean C/N0 (5 s) | 47.9 dB-Hz | **47.9 dB-Hz** (match) |

## Expected
- Logging time drops sharply (no 72k× reflection updates).
- Blanker ~2–4× faster with MEX.
- Correlator self-time drops with MEX (platform dependent).
