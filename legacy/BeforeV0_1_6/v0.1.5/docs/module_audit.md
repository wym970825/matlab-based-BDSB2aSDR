# Module Audit — BDS-3 B2a SDR

Status after first modernization pass. Priority: **acquisition** and **tracking**.

## A. Acquisition (`acquisition_robust_v2fft`)

### Strengths
- Coarse: 1 ms segmented PCPS with explicit flip modes (anti subcode edge cancel).
- Fine: multi-ms pilot coherent + Weil(100) phase search; polarity reference for PLL pull-in.
- STA = INIT / SING supports re-acq from tracking REACQ path.
- Clean inputParser interface; USEFFT option.

### Issues / risks
| ID | Severity | Issue | Recommendation |
|----|----------|-------|----------------|
| A1 | Med | Peak metric / threshold coupling is empirical (`acqThreshold=2`); CFAR not adaptive to PB duty cycle | Adaptive threshold from noise floor after blanking |
| A2 | Med | Full-sky loop is serial over PRN × Doppler; dominant runtime | `parfor` over PRN; precompute FFT of local codes |
| A3 | Low | Fine code refine window may be insufficient at high residual Doppler | Residual-Doppler-aware refine or 2-D local search |
| A4 | Low | `codePhaseAbs` vs file seek alignment depends on skip bytes | Unit-test seek consistency with `preRun2` |
| A5 | Med | No structured logging of per-PRN grid max (hard to pick smoke SV offline) | Always return/export metric table (done in smoke_acquisition) |

### Smoke criteria
- At least 1 PRN with finite `carrFreq` and peakMetric above threshold on baseline IF file.
- Best PRN metric clearly separated from noise floor.

---

## B. Tracking (`tracking2_v6_fix2` + `NH_stateMachine` + `TrackResults2`)

### Strengths
- Data + pilot dual correlators; DLL + Costas/atan2 PLL; optional FLL aiding with 2nd-order LPF.
- NH state machine: INIT / INIT_FLL / LONG / LONG_FLL / ESTI / REACQ with Weil estimator.
- Chunked result save (`TrackResults2`) for long records.
- Pulse blanker integration; scintillation calculator hooks; optional carrier KF.

### Critical bugs found (this pass)

| ID | Severity | Issue | Fix status |
|----|----------|-------|------------|
| T1 | **Critical** | Per-channel `Tres` overwritten; `finalTRes` never returned → nav disconnected | **Fixed**: `trkBuf` + `Tres(c_i)=finalTRes` |
| T2 | **Critical** | Caller `load trackingResults_01` overwrote live results | **Fixed** in `run_B2a` / `runNavigation` |
| T3 | High | Sequential multi-channel: each channel rewinds file (not true multi-SV parallel) | Planned (see optimization_plan.md) |
| T4 | Med | `TrackResults2.save` / `copyFROM` reference undefined `settings` in places | Open — use stored property |
| T5 | Med | Timestamp from BCNAV2 can fail / length mismatch on short runs | **Mitigated** with try/catch + length clamp |
| T6 | Low | Duplicate NV name `'fllDiscrHz'` when intending filtered field (legacy) | Open — verify line and set `fllDiscrFiltHz` |
| T7 | Med | REACQ path external re-acq not fully wired in single-function tracker | Open — design external acq callback |
| T8 | Med | `longCoh_ms=1` default disables true long coherent benefit | Document / revisit for scintillation thesis configs |

### Smoke criteria
- For best PRN, 5 s tracking: pilot prompt power stable, mean C/N0 > ~25 dB-Hz (dataset-dependent).
- No MATLAB exception; `Tres(k).PRN` matches channel; status `'T'`.

---

## C. Navigation (`postNavigation` + BCNAV2)

### Strengths
- Full B-CNAV2 → ephemeris → pseudorange → WLS PVT chain.

### Issues
| ID | Severity | Issue | Fix status |
|----|----------|-------|------------|
| N1 | **Critical** | Upstream trackResults never connected (see T1/T2) | **Fixed** bridge |
| N2 | High | Hard ≥24 s and ≥4 SVs with msg 10/11/30–34 | Documented; smoke skips nav |
| N3 | Med | `eph(PRN)` growth / empty eph edge cases | **Hardened** prealloc + try/catch |
| N4 | Med | `absoluteSample` indexing when subframe start invalid | **Hardened** |
| N5 | Low | Elevation mask freezes excluded SV set historically (TODO in original) | Open |

---

## D. Channel control / estimators

| Module | Notes |
|--------|-------|
| `NH_stateMachine` | Core logic solid; CN0_Th dual use with settings.TrkCN0Th — keep consistent |
| `pulseBlanker` | Static threshold path depends on USRP scaleK/gain calibration |
| `CarrierKF2` / IAKF | Optional; off by default — good for baseline smoke |
| `scint_calculator` | Heavy; ensure not called when disabled for speed |
| `Calc_CNo_PLD` | Expects struct or object with I/Q fields — dual path in tracker |

---

## E. Code hygiene (cross-cutting)

- Mix of OOP (handle classes) and procedural SDR style — acceptable if contracts documented.
- Many absolute paths in legacy settings — centralized under `initSettings` + overrides.
- `.asv`, `old_version/`, debug zips excluded from refactor tree.
- UTF-8 comments / Chinese design notes retained where informative.

## F. Residual open items (next iterations)

1. Wire REACQ → `acquisition_robust_v2fft(...,'STA','SING')` and resume.
2. Fix `TrackResults2` internal `settings` references.
3. Multi-channel parallel tracking (plan only this round).
4. MEX for correlator inner loop (plan only this round).
5. Navigation smoke with ≥4 SVs × ≥30 s once track quality confirmed.
