# Smoke Report v1 (2026-07-30)

## Environment
- MATLAB R2024b
- IF: `F:\Data\DME_BDSB2a\Experiment\2022BJ\DATA1020\300sData_@111407_…ZeroIF.bin`
- Project: `F:\matlab-GNSSsdr\BDS\B2a`

## Acquisition (`smoke_acquisition`, full sky 1..63)

| Metric | Value |
|--------|-------|
| Wall time | ~131 s |
| Acquired PRNs | 23, 24, 25, 27, 32, 38, 39, **41** |
| Best by peakMetric | **PRN 41** (13.215) |
| Strong set | 41 (13.2), 39 (10.8), 38 (10.8), 25 (5.8), 27 (5.3), 24 (4.3) |

Legacy default list `[24,38,39,41]` all acquired successfully.

Artifact: `results/smoke/acq_260730_101607.mat`

## Tracking (`smoke_tracking`, PRN 41, 5000 ms)

| Metric | Value |
|--------|-------|
| Wall time | ~26 s (≈5× real-time) |
| Status | T |
| mean / max C/N0 | 47.9 / 52.0 dB-Hz |
| State progression | INIT_FLL → LONG (~3 s) |
| Return path | `Tres(1)` collected with PRN 41 |

Artifact: `results/smoke/trk_260730_101803.mat`

## Navigation
Not run in this short smoke (needs ≥24 s and ≥4 eph SVs). Pipeline bridge code is in place (`runNavigation`).

## Verdict
**PASS** for acquisition + single-SV tracking + trackResults return fix.
