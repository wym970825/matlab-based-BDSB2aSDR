# BDS-3 B2a SDR — Architecture (Refactored)

## 1. Scope

Modern reorganization of the CU Multi-GNSS B2a SDR (+ FLL-aided / NH state machine /
pulse blanker / scintillation hooks) from:

`…/B2aFLLAided` → `F:\matlab-GNSSsdr\BDS\B2a`

**Constraint:** input tree is read-only; all writes and iteration happen under the output path with git.

## 2. Legacy entry points & dependency map

| Entry | Settings | Core chain |
|-------|----------|------------|
| `init_B2a.m` | `initSettings` | acq → preRun2 → tracking2_v6_fix2 → (**bug**) `load trackingResults_01` → postNavigation |
| `init_B2a_tmp.m` | `initSettings_tmp` | same chain, different IF file |
| `init_B2a_hur1.m` | `initSettings_hur1` | same chain |
| `init_B2a_hur2.m` | `initSettings_hur2` | same chain |

Shared runtime dependencies (active path only):

```
init_* 
  ├─ initSettings_*
  ├─ acquisition_robust_v2fft
  │    ├─ generateB2aPilotCode / GenWeil / makeB2a*
  │    └─ (optional) pulseBlanker
  ├─ preRun2 / showChannelStatus
  ├─ tracking2_v6_fix2
  │    ├─ NH_stateMachine, TrackResults2, CarrierKF*
  │    ├─ generateB2aDataCode / PilotCode / GenWeil
  │    ├─ Calc_CNo_PLD, calcLoopCoef, pulseBlanker, scint_calculator
  │    └─ BCNAV2decoding (timestamp assist)
  └─ postNavigation
       ├─ BCNAV2decoding, eph_structure_init, ephemeris
       ├─ calculatePseudoranges, satpos1
       ├─ leastSquarePos, cart2geo, cart2utm, tropo, …
       └─ plotNavigation / plotTracking_NHSMKF
```

`../Common` utilities are vendored into `common/`.

## 3. New directory layout

```
B2a/
  setupPaths.m          path bootstrap
  init_B2a.m            legacy-named entry → run_B2a
  config/               initSettings (+ overrides)
  core/                 pipeline orchestration
  acquisition/          robust PCPS + fine Weil acq
  tracking/             FLL-aided tracking loop
  navigation/           BCNAV2 decode + PVT
  channelCtrl/          NH SM, TrackResults2, KF, PB, scint
  signal/               spreading / Weil code generators
  include/              plot, probe, preRun helpers
  common/               shared GNSS math
  cn0/                  C/N0 estimators
  tests/                smoke_acquisition / smoke_tracking
  docs/                 design & audit
  results/              run outputs (gitignored large mats)
```

## 4. Pipeline (refactored)

```
setupPaths
  → initSettings(Name,Value)
  → openIfFile
  → runAcquisition  (optional PB → acquisition_robust_v2fft)
  → preRun2
  → tracking2_v6_fix2   **returns full TrackResults2 array**
  → runNavigation       **uses live trackResults (no stale load)**
  → plot* / save
```

### Critical legacy bug fixed

1. **Tracking return path:** per-channel `finalTRes` was only written to disk; return value `Tres` was overwritten each channel. Now `Tres(c_i) = finalTRes`.
2. **Stale navigation input:** `init_B2a` called `load trackingResults_01` after tracking, discarding live results. Removed; `runNavigation` bridges object → struct for `postNavigation`.

## 5. Data contracts

### Acquisition → Channel

| Field | Meaning |
|-------|---------|
| carrFreq | IF-domain carrier [Hz] |
| codePhase | sample index (1-based) |
| weilPhase | Weil(100) phase 0..99 |
| polarityRef | ±1 pilot polarity |
| peakMetric | detection statistic |

### Tracking → Navigation

| Field | Meaning |
|-------|---------|
| PRN, status | channel id / 'T' or '-' |
| I_P | data prompt I (bit stream for BCNAV2) |
| absoluteSample | IF sample index per ms |
| Pilot_* / codeFreq / carrFreq | observations |

Navigation requires ≥24 s of tracking and ≥4 SVs with message types 10, 11, and one of 30–34.

## 6. Configuration baseline (`initSettings`)

Matches original `init_B2a` smoke dataset:

- File: `F:\Data\DME_BDSB2a\Experiment\2022BJ\DATA1020\300sData_@111407_…ZeroIF.bin`
- fs = 20 MHz, IQ int16, IF = 0
- Default PRN list: `[24, 38, 39, 41]`
- PB enabled; FLL aiding enabled; KF default off

## 7. How to run

```matlab
cd('F:\matlab-GNSSsdr\BDS\B2a')
setupPaths

% Full-sky acquisition smoke
smoke = smoke_acquisition('fullSky', true);

% Single-SV short track smoke
smoke = smoke_tracking('acqSatelliteList', smoke.bestPrn, 'msToProcess', 5000);

% Full pipeline (long)
results = run_B2a('msToProcess', 60000, 'acqSatelliteList', [24 38 39 41]);
```
