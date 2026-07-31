# Multi-segment TOW + optional LS weights

## Epoch-wise LS (REACQ-aware)

Mid-session REACQ invalidates a single first-preamble TOW for later ms.
Navigation no longer keeps only the **last** REACQ segment.

| Component | Behaviour |
|-----------|-----------|
| `decodeEphWithReacqResync` | Split track at REACQ (`trk_state==9`); decode each lock run ≥24 s |
| `towSeg{ch}(k)` | `indexStart/indexEnd/subFrameStart/TOW` per segment |
| `calculatePseudoranges` | Pick the segment that contains the measurement index |
| `postNavigation` window | `sampleStart = min(first-segment)` — not `max(last-REACQ)` |
| Fix gate | **nSat ≥ 4** at that epoch (LS); missing SVs simply drop out |

Pre-REACQ epochs remain usable; REACQ gaps contribute `tt=inf` for that SV.

## Optional observation weights (`settings.lsWeight`)

Default: both off → equal-weight LS.

```matlab
settings.lsWeight.enableElev = false;  % sin(el)^elevExp
settings.lsWeight.enableCno  = false;  % 10^((C/N0 - cnoRefDb)/10)
settings.lsWeight.elevExp    = 2;
settings.lsWeight.elFloorDeg = 5;      % sin floor before elev power
settings.lsWeight.cnoRefDb   = 40;     % dB-Hz unit-weight reference
settings.lsWeight.wMin       = 0.05;   % floor after product / re-scale
settings.lsWeight.wMax       = 1.0;    % ceiling before max-normalise
```

`w = clamp(w_el * w_cno)`; then scale so `max(w)=1` and re-apply `wMin`.
Elev for weight uses the **previous epoch** elevation vector (`satElev`); C/N0
from `B2a_CNo` at the measurement index (`CNoInterval` bins).

WLS is applied inside `leastSquarePos` / RAIM subsets. Reported residuals stay
in **metres (unweighted)** so RAIM gates remain meaningful.

## Smoke re-nav (no re-track)

```matlab
S = load('results/smoke/fullsky_pvt60_260731_063450/results.mat');
tr = S.report.trackResults;
settings = initSettings('msToProcess', 280000);
% settings.lsWeight.enableElev = true;
% settings.lsWeight.enableCno  = true;
[nav, eph] = postNavigation(tr, settings);
```

### 280 s fullsky (same track as last-REACQ-only run)

| | last-REACQ only | multi-segment TOW |
|--|----------------:|------------------:|
| nFixes (finite LLA) | ~197 | **541** / 557 epochs |
| TOW segments / SV | 1 (post-REACQ) | **2** (pre + post) |
| median height | ~52 m | **~55 m** |
| mean height | ~52 m | pulled by transition outliers |

Collective REACQ gap (~epoch 331+) re-seeds `localTime` after ≥2 no-fix epochs.
