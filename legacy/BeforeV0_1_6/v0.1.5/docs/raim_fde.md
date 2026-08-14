# RAIM single/dual-SV fault exclusion

## Design

Solution-separation FDE in `navigation/raimLeastSquarePos.m`, called from
`postNavigation` when `settings.raim.enable` is true (default).

| Mode | Requirement | Action |
|------|-------------|--------|
| `all` | n ≥ 4 | all-in-view LS |
| `fde1` | n ≥ 5 | try every single-SV exclusion |
| `fde2` | n ≥ 6 | try every dual-SV exclusion |

Integrity gates (defaults in `initSettings`):

- residual RMS ≤ `raim.maxRmsM` (80 m)
- max \|residual\| ≤ `raim.maxResM` (200 m)
- \|r\|_ECEF ∈ [5.5e6, 7.5e6] m

If all-in-view fails, enumerate FDE subsets and pick lowest score among
passing candidates (prefer fewer exclusions). `alwaysSearch=false` skips
enumeration when all-in-view already passes.

## Smoke (fullsky 60 s re-nav)

Data: `results/smoke/fullsky_pvt60_260730_173603/results.mat` trackResults.

| | before RAIM | after RAIM |
|--|------------:|-----------:|
| good \|h\|&lt;5 km | 38/117 | **117/117** |
| mean h | ~−123 km | **53.2 m** |
| mean lat/lon | mixed | **40.3207 / 116.7586** |
| FDE | — | fde1×79 exclude **PRN23** |

Root cause of prior “fly-off”: PRN23 pseudorange step ~280 km from epoch 39;
single-SV FDE removes it, residual RMS ~1 m.

## Outputs

`navSolutions.raim`:

- `mode` — `all` / `fde1` / `fde2` / `fail`
- `excludedPRN`, `nExcluded`
- `residualRms`, `maxResidual`, `passed`
