# Full-sky lock diagnostic report

**Date:** 30-Jul-2026 16:29:50  
**Branch focus:** par-fast-matlab multi-SV track  
**Search list:** PRN 1:60  
**Track length:** 40000 ms  
**Acq wall:** 89.7 s  |  **Track wall:** 221.3 s  
**useParfor:** 1  **parMaxWorkers:** 6  
**Output:** `F:\matlab-GNSSsdr\BDS\B2a\results\smoke\fullsky_lock_260730_162438`

## 1. Acquisition summary

Acquired **8** PRNs: `[23;24;25;27;32;38;39;41]`

| PRN | peakMetric | acq Doppler (Hz) | mean C/N0 | LONG% | REACQ eps | unlocks | problem |
|----:|----------:|---------------:|----------:|------:|----------:|--------:|:-------:|
| 25 | 5.802 | -1329.0 | 28.4 | 0.0 | 0 | 0 | **YES** |
| 27 | 5.335 | 1625.0 | 28.4 | 0.0 | 0 | 0 | **YES** |
| 32 | 3.785 | -1474.0 | 28.7 | 0.0 | 0 | 0 | **YES** |
| 23 | 2.848 | -2491.0 | 28.7 | 0.0 | 0 | 0 | **YES** |
| 41 | 13.215 | 276.0 | 50.1 | 92.5 | 0 | 0 |   |
| 39 | 10.817 | -636.0 | 49.8 | 92.5 | 0 | 0 |   |
| 38 | 10.813 | 90.0 | 50.0 | 92.5 | 0 | 0 |   |
| 24 | 4.254 | 796.0 | 45.2 | 92.5 | 0 | 0 |   |

## 2. Problem satellites (focus)

Flagged PRNs: **[25 27 32 23]**

Criteria (any): ≥2 REACQ episodes; ≥2 unlocks; LONG%<70 after lock; REACQ sample share>5%; never LONG; weak C/N0 near TrkCN0Th with unlock.

### PRN 25

| metric | value |
|---|---:|
| status | T |
| peakMetric (acq) | 5.802 |
| acq carrFreq | -1329.0 Hz |
| mean/min/p10/max C/N0 | 28.4 / 15.3 / 26.7 / 31.6 |
| LONG% | 0.0 |
| max continuous LONG | 0 ms |
| first LONG / first unlock | NaN / NaN ms |
| REACQ episodes / sample% | 0 / 0.0% |
| unlock / relock edges | 0 / 0 |
| |carrFreq| jumps >50 Hz | 3773 (max 15715.9 Hz) |
| fill% (finite I_P) | 99.9 |
| state hist | UNK:0.1% INIT:0.4% INIT_FLL:99.4% |
| reasons | never_LONG |

**Likely causes (heuristic):**

- **Weak signal**: mean C/N0 (28.4) near TrkCN0Th (25.0) → NH SM trips REACQ often.
- **Never reached LONG**: INIT/Weil estimate failed or CN0 invalid during pull-in; inspect INIT duration and polarity/Weil from acq.

### PRN 27

| metric | value |
|---|---:|
| status | T |
| peakMetric (acq) | 5.335 |
| acq carrFreq | 1625.0 Hz |
| mean/min/p10/max C/N0 | 28.4 / 14.0 / 26.6 / 31.6 |
| LONG% | 0.0 |
| max continuous LONG | 0 ms |
| first LONG / first unlock | NaN / NaN ms |
| REACQ episodes / sample% | 0 / 0.0% |
| unlock / relock edges | 0 / 0 |
| |carrFreq| jumps >50 Hz | 3732 (max 28748.3 Hz) |
| fill% (finite I_P) | 99.9 |
| state hist | UNK:0.1% INIT:0.5% INIT_FLL:99.4% |
| reasons | never_LONG |

**Likely causes (heuristic):**

- **Weak signal**: mean C/N0 (28.4) near TrkCN0Th (25.0) → NH SM trips REACQ often.
- **Never reached LONG**: INIT/Weil estimate failed or CN0 invalid during pull-in; inspect INIT duration and polarity/Weil from acq.

### PRN 32

| metric | value |
|---|---:|
| status | T |
| peakMetric (acq) | 3.785 |
| acq carrFreq | -1474.0 Hz |
| mean/min/p10/max C/N0 | 28.7 / 15.2 / 27.2 / 32.1 |
| LONG% | 0.0 |
| max continuous LONG | 0 ms |
| first LONG / first unlock | NaN / NaN ms |
| REACQ episodes / sample% | 0 / 0.0% |
| unlock / relock edges | 0 / 0 |
| |carrFreq| jumps >50 Hz | 3872 (max 20972.0 Hz) |
| fill% (finite I_P) | 99.8 |
| state hist | UNK:0.2% INIT:0.5% INIT_FLL:99.3% |
| reasons | never_LONG |

**Likely causes (heuristic):**

- **Weak signal**: mean C/N0 (28.7) near TrkCN0Th (25.0) → NH SM trips REACQ often.
- **Never reached LONG**: INIT/Weil estimate failed or CN0 invalid during pull-in; inspect INIT duration and polarity/Weil from acq.

### PRN 23

| metric | value |
|---|---:|
| status | T |
| peakMetric (acq) | 2.848 |
| acq carrFreq | -2491.0 Hz |
| mean/min/p10/max C/N0 | 28.7 / 15.3 / 27.3 / 31.1 |
| LONG% | 0.0 |
| max continuous LONG | 0 ms |
| first LONG / first unlock | NaN / NaN ms |
| REACQ episodes / sample% | 0 / 0.0% |
| unlock / relock edges | 0 / 0 |
| |carrFreq| jumps >50 Hz | 3661 (max 21050.0 Hz) |
| fill% (finite I_P) | 99.9 |
| state hist | UNK:0.1% INIT:0.3% INIT_FLL:99.7% |
| reasons | never_LONG |

**Likely causes (heuristic):**

- **Weak signal**: mean C/N0 (28.7) near TrkCN0Th (25.0) → NH SM trips REACQ often.
- **Marginal acquisition**: peakMetric=2.85 close to threshold → possible false peak / poor code-phase.
- **Never reached LONG**: INIT/Weil estimate failed or CN0 invalid during pull-in; inspect INIT duration and polarity/Weil from acq.

## 3. Stable satellites (reference)

- PRN **41**: LONG=92.5% meanCNo=50.1 unlocks=0 REACQ_eps=0 peak=13.21
- PRN **39**: LONG=92.5% meanCNo=49.8 unlocks=0 REACQ_eps=0 peak=10.82
- PRN **38**: LONG=92.5% meanCNo=50.0 unlocks=0 REACQ_eps=0 peak=10.81
- PRN **24**: LONG=92.5% meanCNo=45.2 unlocks=0 REACQ_eps=0 peak=4.25

## 4. System-level notes

- `TrkCN0Th` = 25.0 dB-Hz (REACQ trigger threshold in NH SM).
- `CNo_Th` = 30.0 dB-Hz.
- `REACQ_max` = 5 attempts before give-up.
- Pulse blanker EnablePB = 1.
- Parallel track: private IF fopen per SV; max workers 6.
- Figures under `figures/` for problem PRNs (state/CNo/Doppler).

---

## 5. Root-cause diagnosis (focus PRNs)

### 5.1 Two populations after PRN 1:60 search

| Class | PRNs | peakMetric | mean C/N0 | Pilot med \|P\|² | LONG% | trk_state |
|-------|------|------------|-----------|------------------|-------|-----------|
| **Stable** | 41, 39, 38, **24** | 4.3–13.2 | **45–50** dB-Hz | ~1e8–4e8 | **92.5%** | LONG (id=3) after ~3 s INIT |
| **Unstable / stuck** | **25, 27, 32, 23** | 2.8–5.8 | **~28.5** dB-Hz | **~3e6** (~100× weaker) | **0%** | **INIT_FLL ~99%** |

Important: **PRN 24** has peakMetric only 4.25 (similar order to problem set) but tracks solidly at 45 dB-Hz.  
→ peakMetric alone does **not** separate real weak GEO/IGSO from false or degraded locks; **post-pull-in C/N0 and pilot power** do.

### 5.2 What “失锁 / 中断” looks like here

On problem SVs the failure mode is **not** “LONG then unlock repeatedly” in the log sense of `cur_state` edges. Instead:

1. Acq declares a peak and channel starts as `T`.
2. Tracker stays in **INIT / INIT_FLL** for the entire 40 s (never enters LONG).
3. Pilot power stays ~100× below healthy SVs; C/N0 hovers ~28 dB-Hz with **min ~14–15**.
4. NH state machine: `any(CN0 < TrkCN0Th=25) && all(CN0>0)` → **`enterReacq()`**, which **resets `T_init`**.
5. LONG requires continuous INIT time ≥ `trackInit_MS` (3000 ms) then Weil ESTI success. Repeated REACQ **prevents ever accumulating 3 s clean INIT**.
6. Runtime log shows **many `REACQ fseek`** (34 total this run, concentrated on PRN 23/32/…); REACQ ms are **under-counted in `trk_state`** because the REACQ branch `continue`s **before `writeTick`**, so id=9 is rarely stored. Prefer log `REACQ fseek` + INIT_FLL% + never_LONG for diagnosis.

So the user-visible symptom is: **captured but never stable-lock, with REACQ churn and FLL thrash**, not classical LONG↔REACQ square-wave on strong SVs.

### 5.3 Per-problem PRN

| PRN | peak | C/N0 mean/min | pol (acq) | Weil | Notes |
|----:|-----:|---------------|:---------:|-----:|-------|
| **25** | 5.80 | 28.4 / 15.3 | −1 | 26 | **Highest false-looking peak among failures**; coarse mode pilot/data asymmetric (log: mode 1 and 8). Strong candidate for **false peak / wrong code phase** or half-chip offset — acq metric overconfident vs track power. |
| **27** | 5.34 | 28.4 / 14.0 | −1 | 0 | Same power class as 25; polarity −1; never LONG. |
| **32** | 3.79 | 28.7 / 15.2 | +1 | 7 | Multiple REACQ handovers late in run (log ~28–40 s); C/N0 often <25 on one of data/pilot → REACQ loop. |
| **23** | **2.85** | 28.7 / 15.3 | −1 | 19 | **Barely above acqThreshold=2**; most likely **marginal/false acq**. Large Doppler (~2.5 kHz). |

Stable contrast: PRN **24** peak=4.25, C/N0~45, LONG 92% — real SV, slightly weaker than 38/39/41.

### 5.4 Mechanism chain (problem set)

```
weak/false acq peak
    → low correlator power (~3e6)
    → C/N0 ~28 with dips < TrkCN0Th(25)
    → NH enterReacq() resets T_init
    → never reach trackInit_MS (3000) cleanly
    → stuck INIT_FLL; FLL still runs → Doppler wander / jumps
    → REACQ buffer re-acq may re-lock to same weak peak → repeat
```

Secondary factors:

- **Polarity −1** on 23/25/27: if pilot wipe-off or Costas path mishandles reference, pull-in degrades (24 is +1 and healthy — not sole cause, but worth checking on −1 set).
- **REACQ handover** (`fseek` by codePhase in last 1 ms): if acq on weak SV is noisy, handover injects phase/code error and keeps CN0 low.
- **CNo estimator during INIT**: using dual-channel CN0 with one leg noisy can trip `any(CN0 < Th)` even when pilot looks OK.

### 5.5 Recommended fixes (priority)

| Pri | Change | Why |
|----:|--------|-----|
| P0 | **Acq gate for track**: require peakMetric ≥ ~4 **and/or** post-1 s mean pilot C/N0 ≥ 32 before committing channel | Drop 23; scrutinize 25/27/32 early |
| P0 | **REACQ trigger hysteresis**: enter REACQ only if CN0 < Th for N consecutive CNo epochs (e.g. 3×200 ms), not single epoch | Stops T_init reset thrash near threshold |
| P1 | **Log REACQ in `writeTick` / trk_state** even on REACQ branch | Diagnostics currently blind to id=9 |
| P1 | **Track-quality veto**: if after `trackInit_MS` still not LONG and mean C/N0 < 32, drop channel (status `F`) instead of spinning REACQ | Saves CPU; cleaner nav |
| P2 | Review **PRN25** fine peak (mode 1 vs 8) — possible cross-corr / side lobe | High peakMetric, low track power |
| P2 | Slightly raise `acqThreshold` (2.0 → 3.0) for this IF | Cuts PRN23-class ghosts |
| P3 | Soften `TrkCN0Th` for INIT only (e.g. 22) while keeping LONG at 25 | Optional; hysteresis is safer |

### 5.6 Nav implication

For PVT, prefer **{41, 39, 38, 24}** on this dataset.  
Including {25, 27, 32, 23} will pollute measurements (unlocked Doppler, invalid C/N0 during REACQ) unless gated.

### 5.7 Artifacts

- Report + mat: `results/smoke/fullsky_lock_260730_162438/`
- Figures: `figures/prn{23,25,27,32}_timeline.png`, `overview_long_reacq.png`
- Runner: `tests/run_fullsky_lock_diag.m`
