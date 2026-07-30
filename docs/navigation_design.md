# Design: Navigation (PVT) Bridge

## Problem (legacy)

After tracking, `init_B2a.m` executed:

```matlab
[trackResults, channel] = tracking2_v6_fix2(...);
...
load trackingResults_01   % overwrites trackResults
[navSolutions,eph] = postNavigation(trackResults, settings);
```

Combined with tracking not returning assembled results, **PVT was fully decoupled**
from the live tracking session.

## Solution

```
trackResults (TrackResults2[])
    → trackResultsToStruct
    → postNavigation
         → BCNAV2decoding(I_P)
         → calculatePseudoranges
         → satpos1 + leastSquarePos
         → cart2geo / cart2utm
```

Entry: `core/runNavigation.m` and `core/run_B2a.m`.

## Requirements

| Requirement | Value |
|-------------|-------|
| Track length | ≥ 24 000 ms (B-CNAV2 messages) |
| Active SVs with eph | ≥ 4 (types 10, 11, and one of 30–34) |
| Track fields | `I_P`, `absoluteSample`, `PRN`, `status` |

## Hardening in this pass

- Accept TrackResults2 or struct.
- Pre-allocate `eph(1:63)`.
- Guard invalid subframe indices on `absoluteSample`.
- Try/catch per-channel decode.

## Smoke strategy

1. Track smoke (short) — no PVT.
2. Multi-SV ≥30 s when acq quality confirmed — enable `doNavigation=true`.
