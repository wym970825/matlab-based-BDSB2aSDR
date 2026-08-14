# Design: B2a Tracking (FLL-aided)

## Purpose

Millisecond-rate code/carrier tracking of B2a data + pilot, with NH/Weil phase
management, optional FLL aiding, pulse blanking, and result logging suitable
for BCNAV2 bit recovery and scintillation metrics.

## State machine (`NH_stateMachine`)

```
INIT ──(Weil conf OK)──► LONG
  │                        │
  │ CN0 low                │ CN0 low / re-estimate timer
  ▼                        ▼
REACQ ◄────────────────── ESTI (Weil re-estimate, zero-hold)
```

FLL sub-states: `INIT_FLL`, `LONG_FLL` when frequency error persists above thresholds.

PLL filter coefficients: pull-in → stable (INIT) → long-coherent (LONG).

## Loop architecture (per 1 ms)

1. Read IF block; optional pulse blanker.
2. Code NCO early/prompt/late for data & pilot.
3. Carrier wipe-off (NCO phase continuous).
4. Discriminators: DLL (normalized E-L), PLL (Costas/atan2), FLL (cross-product / folded).
5. Loop filters → update `codeFreq`, `carrFreq`.
6. NH wipe-off on pilot when LONG; buffer for Weil estimator.
7. C/N0 + PLD every `CNoInterval` ms.
8. Log into `TrackResults2` (chunked autosave).

## Result container

`TrackResults2` (handle): field-compatible with legacy struct for plots and nav.
Methods: `update`, `toStruct`, `save`/`partsave`, `copyFROM`, `estimateLoopNoise`.

## Refactor change

Tracking now returns a full channel-aligned `TrackResults2` array after assembling
chunked `finalTRes` per PRN. Callers must not load external stale MAT files.

## Test

`tests/smoke_tracking.m` — 5 s default on one strong PRN; correlator quick-look.
