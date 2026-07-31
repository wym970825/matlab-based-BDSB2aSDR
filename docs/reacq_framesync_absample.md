# REACQ absoluteSample + frame re-sync

## Problem

1. REACQ path used `continue` **without** `writeTick` → `absoluteSample` holes (NaN).
2. `postNavigation` used **first-preamble only** TOW/`subFrameStart` for the whole track.
3. Each SV REACQs at a different time → old TOW + code index no longer match → multi-100 km PR jumps.

## Fix

### Tracking (`trackOneChannel`)

- Every REACQ 1 ms: log `absoluteSample = ftell/size_per_sample`, `trk_state=9`, zero correlators.
- On REACQ success: full loop re-init + force NH `INIT` (Weil/frame re-sync path).
- Record `ch.reacqLoopCnt` for diagnostics.

### Navigation

- `decodeEphWithReacqResync`: if `trk_state==9` present, re-run `BCNAV2decoding` on `I_P` **after last REACQ** and remap `subFrameStart`.
- `calculatePseudoranges`: skip non-finite `absoluteSample` and `trk_state==9`; NaN PR for invalid tt.
- `postNavigation`: only channels with finite tt enter LS/RAIM that epoch.

## Note

Re-running PVT on **old** track mats still has NaN `absoluteSample` during REACQ; needs **re-track** for full benefit. Frame re-sync alone helps if I_P after REACQ is usable.
