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

### Correlator MEX internals (v2)
- **Carrier NCO**: `uint32` phase accumulator (Q32 cycles), not `cos(2*pi*f*t)` per sample.
- **LUT**: 4096-point float cos/sin table (12-bit phase).
- **SSE2**: process 2 samples/iter for code×baseband MAC.
- **Code E/P/L indices**: still scalar (data-dependent).

### Scintillation
- `settings.scint_updateMs = 5000` (5 s): `push` remains 1 ms; filter/stats batch every 5 s.

## Smoke
```matlab
setupPaths
build_mex
smoke = smoke_tracking('acqSatelliteList',41,'msToProcess',5000,'doQuickPlot',false);
rankT = profile_track_hotspots('msToProcess',8000,'acqSatelliteList',41);
```

## Benchmark (PRN 41, same IF file)

| Metric | pure MATLAB | mex v1 | **v2 LUT+SSE2 + scint 5s** |
|--------|------------:|-------:|---------------------------:|
| 5 s track wall | 26.2 s | 14.4 s | **4.8 s (~1.04× real-time)** |
| 8 s profile wall | 33.8 s | 22.1 s | **~12 s** |
| correlator MEX | — | ~5.3 s | **~1.6 s** (LUT NCO) |
| blanker | 3.7 s | 1.1 s | ~0.7 s |
| scint push+tick | ~1.3 s | ~1.3 s | **~0.16 s** (5 s batch) |
| mean C/N0 (5 s) | 47.9 | 47.9 | **47.9** |

Single-SV tracking is **at / slightly above real-time** at 20 Msps after v2.

## Expected
- Logging time drops sharply (no 72k× reflection updates).
- Blanker ~2–4× faster with MEX.
- Correlator self-time drops with MEX (platform dependent).
