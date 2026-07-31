# Carrier-aided code: 4SV×5s smoke comparison

**Config:** serial, PRN [25 27 32 23], `msToProcess=5000`, DLL pull 10 Hz / PLL 50–30  
**Baseline (before aid):** `results/smoke/pullin_fll_260730_172918` (DLL 10 only)  
**After aid (sign-corrected):** `results/smoke/pullin_fll_260730_181113`

## Formula (final)

```matlab
aid = -carrFreq * (codeFreqBasis / carrFreqBasis);  % polarity matched to this SDR
aid = clamp(aid, ±carrierAidCodeMaxHz);             % default 50 Hz code-domain
codeFreq = codeFreqBasis + aid - codeNco;
```

Sign: locked tracks show `(codeFreq−f0) ≈ −carrFreq·(f0/fL)` under this wipe-off convention.

## FLLoff metrics

| PRN | LONG% before | LONG% after | \|dll\| before | \|dll\| after | notes |
|----:|-------------:|------------:|---------------:|--------------:|-------|
| 25 | 40 | **40** | 0.079 | **0.077** | solid |
| 27 | 40 | **40** | 0.093 | **0.090** | solid |
| 32 | 40 | **40** | 0.080 | **0.076** | solid |
| 23 | 40 | **40** | 0.153 | **0.147** | firstWeak 18→1617 ms (less early collapse) |

FLLon: same LONG% pattern after sign fix (all 40%).

## Wrong-sign trial (intermediate)

`aid = +carrFreq·ratio` caused **PRN23 LONG%→0** while 25/27/32 still held (DLL 10 Hz absorbed residual). Confirmed polarity must be **negative** for this receiver.

## Unit checks

| case | dCode |
|------|------:|
| carr=+1000 | −8.70 (after sign fix: wait, -1000 gives +8.7) |
| carr=−1329 | **+11.56** |
| carr=+10000 | clip to **±50** |

## Verdict

- Carrier aid **default ON**, instantaneous `carrFreq`, **±50 Hz** code-domain clamp.  
- No regression vs DLL-10-only on 4 problem SVs; slight \|dll\| reduction; PRN23 early-weak delayed.  
- Main win of DLL-10 remains; aid is correct polarity infrastructure for high Doppler / tighter DLL later.
