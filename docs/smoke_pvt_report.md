# PVT Smoke Report — 4 SV × 38 s

**Date:** 2026-07-30  
**PRNs:** 41, 39, 38, 24  
**msToProcess:** 38000  
**IF file:** `300sData_@111407_…ZeroIF.bin`  
**Artifacts:** `results/smoke/pvt_260730_resume2/`

## 1. Pipeline outcome

| Stage | Result |
|-------|--------|
| Acquisition | 4/4 PASS (all fine-acq OK) |
| Tracking wall | **~755 s** serial (≈5× real-time × 4 SV) |
| Track quality | All 4 stay LONG ~92%; C/N0 mean ≈45–50 dB-Hz |
| B-CNAV2 decode | **4/4** message types 10+11+30–34 OK |
| WLS epochs | 73 (0.5 s `navSolPeriod`) |
| Absolute LLA/UTM | **FAIL** (ECEF radius 35–69 Mm, not Earth surface) |
| Relative ECEF / rawP plots | Exported (see figures) |

### Tracking summary

| PRN | mean C/N0 | max C/N0 | LONG % |
|----:|----------:|---------:|-------:|
| 41 | 49.9 | 53.0 | 92.1 |
| 39 | 49.8 | 51.8 | 92.1 |
| 38 | 50.0 | 51.9 | 92.1 |
| 24 | 45.1 | 48.8 | 92.1 |

### Absolute positioning diagnosis

- `absoluteSample` span ≈ 7.60e8 samples ≈ 38 s × 20 Msps → **sample counters OK**.
- LS solutions finite but \|r\| ≈ 35–70×10³ km (GEO-scale), not ~6371 km.
- Likely causes (next fix iteration):
  1. Relative pseudorange / `startOffset` / TOW hand-off scale.
  2. `satpos1` / B-CNAV2 time system consistency.
  3. Multi-SV common transmit-time alignment after sequential per-SV rewind.
- **Decode path is healthy**; absolute meter-level PVT needs a dedicated PR/time audit.

## 2. Visualizations

Directory: `results/smoke/pvt_260730_resume2/figures/`

| File | Content |
|------|---------|
| `trk_PRN41.png` … `trk_PRN24.png` | Pilot/data correlators, PLL/DLL, Doppler, C/N0 |
| `trk_cno_multi.png` | Four-SV C/N0 overlay |
| `nav_ecef_relative.png` | Mean-centered ECEF scatter + rawP |
| `nav_rawP_map.png` | rawP channel×epoch heatmap |

## 3. Profiler / MEX ROI (8 s single-SV PRN 41)

Wall (acq+track under profile): **33.8 s**  
CSV: `…/profile/profile_mex_rank.csv`

### Top self-time (calls)

| Rank | Function | Self [s] | Calls | Notes |
|-----:|----------|---------:|------:|-------|
| 1 | `TrackResults2.update` | **10.84** | **72 080** | OOP name-value writer; also drives massive `isprop` |
| 2 | `isprop` (via update) | **4.02** | **240 372** | Avoid by direct field writes |
| 3 | `pulseBlanker.mitigate` | **3.74** | **8 000** | Full-rate pulse blanking |
| 4 | `tracking2_v6_fix2` (self residual) | ~10 | 1 | Carrier/code correlator NCO loops |
| 5 | `scint_calculator.push/tick` | ~1.3 | 8 000 each | Optional if scint off |
| 6 | `NH_stateMachine.update` | 0.49 | 8 000 | Keep in MATLAB OK |
| 7 | `acquisition_robust_v2fft` | 1.96 | 1 | Full-sky would scale with PRN |

### Recommended MEX / rewrite order

1. **Stop using `TrackResults2.update` every ms**  
   - Direct `obj.I_P(k)=…` or preallocated plain struct/arrays.  
   - Expected save: **~15 s / 8 s track** (~45% of wall) without any MEX.
2. **1 ms correlator + carrier wipe-off kernel → MEX**  
   - Extract from `tracking2_v6_fix2` body (E/P/L × data/pilot).  
   - Highest *algorithmic* MEX ROI after (1).
3. **`pulseBlanker.mitigate` → MEX or SIMD**  
   - Simple threshold/blank; 3.7 s / 8 000 ms.
4. **Disable / downsample scint path** when not needed (easy win).
5. **Acquisition FFT code table + PRN `parfor`** for full-sky search (secondary for track-bound runs).
6. **Multi-SV `parfor`** (independent `fopen`) multiplies throughput after per-channel speedup.

### Rough speedup model (4×38 s track)

| Action | Expected track wall |
|--------|---------------------|
| Baseline serial pure MATLAB | ~755 s |
| Fix TrackResults2 logging | ~400–450 s |
| + MEX correlator (~3× kernel) | ~200–250 s |
| + 4-worker parfor | ~60–90 s |
| + MEX blanker | further ~10–15% |

## 4. Code fixes in this round

- REACQ calls `acquisition_robust_v2fft` (+ thin `acquisition_robust_v2` wrapper).
- `trackResultsToStruct` field-set normalization.
- `postNavigation` robust ECEF/LLA/UTM validation (no crash on bad LS).
- `smoke_pvt`, `resume_pvt_from_track`, `profile_track_hotspots`.

## 5. Verdict

| Item | Status |
|------|--------|
| 4 SV × ≥38 s track smoke | **PASS** |
| Visualization (track + relative nav) | **PASS** |
| Profiler / MEX ranking | **PASS** |
| Absolute geodetic PVT | **PARTIAL** (eph OK, LS diverges from Earth) |

Next engineering focus: **pseudorange/time audit for absolute PVT**, then **TrackResults2 write path + correlator MEX**.
