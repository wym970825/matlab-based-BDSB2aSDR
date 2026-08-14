# Pull-in FLL on/off compare (serial, problem PRNs)

PRNs: [25 27 32 23]  msToProcess: 5000  useParfor: false  
Branch: par-fast-matlab (fast/MEX path), serial only  

## Mode `FLLoff` (track 25.5 s)

| PRN | LONG% | meanCNo | P0 | P200 | P1s | dCarr200 | firstWeak | INIT% | LONG_st% |
|----:|------:|--------:|---:|-----:|----:|---------:|----------:|------:|---------:|
| 25 | 0.0 | 28.7 | 2.41e+07 | 3.11e+06 | 3.27e+06 | -166.9 | 25 | 99.9 | 0.0 |
| 27 | 0.0 | 28.0 | 1.76e+07 | 2.13e+06 | 3.45e+06 | -184.9 | 108 | 99.9 | 0.0 |
| 32 | 0.0 | 28.2 | 6.01e+07 | 3.54e+06 | 3.28e+06 | +66.4 | 24 | 99.9 | 0.0 |
| 23 | 0.0 | 28.1 | 3.32e+07 | 3.12e+06 | 3.38e+06 | +1.6 | 14 | 99.9 | 0.0 |

## Mode `FLLon` (track 27.1 s)

| PRN | LONG% | meanCNo | P0 | P200 | P1s | dCarr200 | firstWeak | INIT% | LONG_st% |
|----:|------:|--------:|---:|-----:|----:|---------:|----------:|------:|---------:|
| 25 | 0.0 | 28.3 | 2.41e+07 | 3.25e+06 | 3.14e+06 | -89.9 | 25 | 100.0 | 0.0 |
| 27 | 0.0 | 27.6 | 1.76e+07 | 2.43e+06 | 3.48e+06 | -106.4 | 108 | 99.8 | 0.0 |
| 32 | 0.0 | 28.5 | 6.01e+07 | 3.14e+06 | 3.43e+06 | -9.6 | 24 | 99.9 | 0.0 |
| 23 | 0.0 | 28.7 | 3.32e+07 | 3.08e+06 | 3.4e+06 | +38.1 | 14 | 99.9 | 0.0 |

## Side-by-side LONG%

| PRN | FLLoff LONG% | FLLon LONG% | FLLoff CNo | FLLon CNo |
|----:|-------------:|------------:|-----------:|----------:|
| 25 | 0.0 | 0.0 | 28.7 | 28.3 |
| 27 | 0.0 | 0.0 | 28.0 | 27.6 |
| 32 | 0.0 | 0.0 | 28.2 | 28.5 |
| 23 | 0.0 | 0.0 | 28.1 | 28.7 |

## Verdict

**关 FLL 没有改善**（两侧 LONG% 全 0；`firstWeak` 毫秒数完全一致 → 与 FLL 无关的确定性失效）。

| 观察 | 含义 |
|------|------|
| P0 仍 2e7–6e7 | acq→seek 起始相关正常，不是“参数没传过去” |
| firstWeak 同为 14/24/25/108 ms | 与 FLL 无关；PLL+DLL 闭环在几十 ms 内把锁拉掉 |
| FLLoff 时 dCarr200 仍大（25: −167 Hz） | **PLL 自己在漂**，不是 FLL 独有问题 |
| FLLoff PRN25 前 50 ms：`dllDiscr` 长期卡在 **−0.6~−0.9** | DLL 饱和，码相位系统性偏一侧 |
| `codeFreq−f0` 仅 +3~+5 Hz | 对 \|fd\|≈1.3–2.5 kHz，码多普勒应约 **±11~22 Hz**，**缺载波辅助码环** |

### acq→trk 已核对（未见明显传参错误）

| 字段 | 来源 | 跟踪用法 |
|------|------|----------|
| `carrFreq` | acq 存 `−bestFineFreq` | `carrFreq=ch.acquiredFreq` |
| `codePhase` | 精捕样点相位 | `fseek(skip+(codePhase−1)*bytes)` |
| `polarityRef` | ±1 | `remCarrPhase=(pol<0)*pi` |
| `weilPhase` | 精捕 | 仅 LONG 时 NH wipe；INIT 不用 |
| `codeFreq` | preRun 写死 `codeFreqBasis` | **无载波辅助**：`codeFreq=f0−codeNco` |

### 下一步优先级（FLL 可暂时放下）

1. **载波辅助码 NCO**：`codeFreq = f0*(1+carrFreq/fL) − codeNco`  
2. 查 INIT 段 **pilot Costas + 3 阶 PLL** 在中等 CN0/高多普勒是否过猛  
3. 查 **E–L DLL 饱和**（半码片偏差 / 符号）  
4. 对照稳星 PRN24（fd≈796）与问题星（fd>1.3 kHz）的码多普勒差  

数据目录：`results/smoke/pullin_fll_260730_165906/`  
脚本：`tests/smoke_pullin_fll_off.m`
