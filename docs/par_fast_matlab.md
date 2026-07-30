# par-fast-matlab — multi-SV `parfor` tracking

**Branch:** `par-fast-matlab` (from `mexBaseFast`)  
**Goal:** Parallel multi-satellite tracking in MATLAB, **max 6 workers**.

## Architecture (Option A)

```
IF file ──► worker k: fopen private + trackOneChannel(PRN_k)
            ...
            worker K
                 │
                 ▼
         assemble TrackResults2[]
```

- Shared `fid` is **not** used for multi-channel tracking (race-free).
- Chunk files remain unique per PRN: `Trk_Prn_%02d_*.mat`.
- MEX correlator / blanker from `mexBaseFast` remain available on each worker.

## Settings

| Field | Default | Meaning |
|-------|---------|---------|
| `useParfor` | `true` | Enable parfor when ≥2 active SVs |
| `parMaxWorkers` | `6` | Pool size request; **hard-capped at 6** |

Disable parallel:

```matlab
smoke = smoke_tracking(..., 'useParfor', false);
% or
results = run_B2a(..., 'useParfor', false);
```

## Key files

| File | Role |
|------|------|
| `tracking/trackOneChannel.m` | Single-SV tracker (private IF handle) |
| `tracking/ensureTrackParPool.m` | Start/resize local pool ≤6 |
| `tracking/tracking2_v6_fix2.m` | Serial / parfor dispatcher |
| `config/initSettings.m` | `useParfor`, `parMaxWorkers` |

## Expected speedup

≈ `min(N_sat, N_workers, 6)` if CPU-bound after MEX; less if disk-bound (duplicate reads).

## Smoke

```matlab
setupPaths
% 4 SV, short track
t0 = tic;
s = smoke_tracking('acqSatelliteList',[24 38 39 41], ...
    'msToProcess', 5000, 'doQuickPlot', false, 'useParfor', true, 'parMaxWorkers', 6);
toc(t0)
```
