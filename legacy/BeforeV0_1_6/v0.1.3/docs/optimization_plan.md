# Optimization Plan (Planning Only — This Round)

No parallel or MEX implementation in this iteration; smoke and correctness first.

## 1. Multi-satellite parallel tracking

### Current behavior
`tracking2_v6_fix2` loops channels **sequentially**, each rewinding `fid` to its
`codePhase`. CPU time ≈ N_sat × T_process. Shared file handle is not thread-safe.

### Target architecture

```
                    ┌─ worker 1: PRN A  (memmap / block queue)
IF file ─► reader ──┼─ worker 2: PRN B
                    └─ worker K: PRN K
                              │
                              ▼
                     assemble TrackResults2[]
```

### Options (MATLAB)

| Option | Pros | Cons |
|--------|------|------|
| **A. `parfor` over satellites** with each worker `fopen` own fid | Simple; near-linear if I/O OK | Duplicate I/O bandwidth; disk-bound on HDD |
| **B. Single reader + chunk broadcast** (SPMD / `pollableDataQueue`) | One sequential read | Complex; large RAM for 20 Msps × T |
| **C. Memory-map IF file** (`memmapfile`) + `parfor` | Shared pages; no multi-fopen | Windows pagefile pressure for 22 GB |
| **D. Process batch offline** | Robust | Not “real-time” multi-channel |

**Recommendation:** Phase 1 = Option **A** (independent `fopen` per PRN) for
offline post-processing; Phase 2 = **C** if RAM ≥ 1.5× file size or windowed mmap.

### Required refactors before parallel
1. Extract single-channel tracker: `trackOneChannel(fidOrPath, channel, settings) → TrackResults2`.
2. Remove GUI / figure updates from inner loop (or gate with `settings.plotTracking==0`).
3. Make `pulseBlanker` / `NH_stateMachine` / `TrackResults2` pure per-channel state (already mostly true).
4. Result write paths unique per PRN (already `Trk_Prn_%02d_*.mat`).
5. No shared `fid` mutation across workers.

### Expected speedup
Roughly min(N_sat, N_workers) if CPU-bound correlators; less if disk-bound.

---

## 2. MATLAB → C / MEX for hot loops

### Hotspots (profile expected)

| Hotspot | Location | Why |
|---------|----------|-----|
| H1 | Code NCO + early/prompt/late multiply-accumulate | 20e6 samp/ms × 6 correlators × N_sat |
| H2 | Carrier wipe-off (`exp(-j·)`) | Same sample rate |
| H3 | Acquisition PCPS FFT/IFFT per Doppler × PRN | Coarse search |
| H4 | Pulse blanker thresholding | Full-rate |

### Conversion strategy

1. **Profile** 5 s single-SV track (`profile on`) → confirm H1/H2.
2. **Extract pure functions** with fixed types:
   - `correlateB2aMs(x, codeUpsampled, remCode, codeFreq, remCarr, carrFreq, fs, elSpacing)`
3. **codegen / mex** with `coder.typeof` for complex int16/double.
4. Keep MATLAB outer state machine (NH, FLL, KF) for flexibility.
5. Optional: SIMD-friendly C (AVX2) for E/P/L three-tap simultaneously.

### Data type plan
- Input IF: int16 IQ → promote to single/double in MEX once.
- Local code: int8 ±1 tables, upsample by residual phase.
- Accumulators: double (or single if error budget OK).

### Validation
Bit-exact or near-exact vs MATLAB reference for 1000 ms; C/N0 delta < 0.1 dB;
discriminator RMS difference bound.

### Non-goals (this plan)
- Full receiver in C++
- GPU (unless later H3 only with `gpuArray`)

---

## 3. Acquisition speedups (lighter than MEX)

1. Precompute FFT of all local codes once per fs.
2. `parfor` over PRN list.
3. Hierarchical Doppler: coarse step 500 Hz → fine 125 Hz only near peaks.
4. Early-exit PRN if coarse metric << threshold.

---

## 4. Suggested implementation order (next coding rounds)

1. Extract `trackOneChannel` + unit smoke (serial parity).
2. `parfor` multi-SV track with private file handles.
3. Profile → MEX correlator.
4. Acq PRN `parfor` + code FFT cache.
5. End-to-end timing report vs baseline.

## 5. Acceptance metrics

| Metric | Baseline (serial pure MATLAB) | Target |
|--------|-------------------------------|--------|
| Track 4 SV × 30 s wall time | T0 | ≤ T0 / min(4, cores) × 1.3 |
| Single SV 1 ms correlator time | t_ms | ≤ 0.3 · t_ms after MEX |
| Nav solution availability | same as serial | no regression |
