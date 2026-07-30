# Design: B2a Acquisition

## Purpose

Detect BDS-3 B2a pilot (and support tracking hand-off) under Doppler, code delay,
and secondary-code (Weil-100) phase uncertainty, including DME-like pulsed RFI
when pulse blanking is enabled.

## Algorithm summary

### Coarse (1 ms)

1. Generate local pilot primary code (no NH) at IF sampling rate.
2. Segment 1 ms into 8 × 0.125 ms blocks (implementation uses 8 flip modes).
3. For each Doppler bin and flip hypothesis, PCPS correlation.
4. Peak metric ≈ peak / mean (or CPPR-like) vs `acqThreshold`.

### Fine

1. Around coarse Doppler, refine frequency with multi-ms coherent pilot integration.
2. Estimate Weil(100) start phase.
3. Optional local code-phase refine (± `fineCodeSearchHalfWinSamples`).
4. Output `polarityRef` from pilot coherent sum for PLL phase initialization.

## Interfaces

```matlab
acqResults = acquisition_robust_v2fft(longSignal, settings, ...
    'STA','INIT','USEFFT',false);
% or re-acq:
acqResults = acquisition_robust_v2fft(longSignal, settings, ...
    'STA','SING','PRN',prn);
```

Required `settings` fields: `samplingFreq`, `codeFreqBasis`, `codeLength`,
`acqSatelliteList`, `acqSearchBand`, `acqStep`, `acqThreshold`, `fineNoncoh`, `IF`.

## Hand-off to tracking

`preRun2` maps strongest acquired PRNs into `channel(i)` with:

- `acquiredFreq`, `codePhase`, `weilPhase`, `polarityRef`, `status='T'`.

## Upgrades vs legacy CU acq

- Robust flip modes vs secondary-code edges.
- Explicit fine Weil phase + polarity for NH wipe-off tracking.
- Structured STA for REACQ integration.

## Test

`tests/smoke_acquisition.m` — full-sky or list scan, export best PRN.
