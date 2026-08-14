# Plan: 载波辅助码环（Carrier-Aided Code Loop）

**分支建议：** `par-fast-matlab`（主开发；同步 `mexBaseFast` / `master`）  
**状态：** 仅计划，未实现  
**背景：** DLL pull-in 10 Hz 已让 23/25/27/32 进 LONG；高多普勒下码多普勒仍全靠 DLL，载波辅助是标准下一步。

---

## 1. 目标

在 **不改鉴相/鉴频器结构** 的前提下，把载波环估计的多普勒按频率比馈入码 NCO，使 DLL 只跟踪 **残余码相位误差**（动力学更低），从而：

1. 高多普勒星（\|fd\| ≳ 1 kHz）pull-in / 稳态更稳  
2. 允许后续把稳态 DLL Bn 收得更紧（可选）  
3. 与 SoftGNSS / ICD 常见做法一致  

**非目标（本轮）：** 码辅助载波、KF 耦合、改 FLL 增益、改捕获。

---

## 2. 原理（简）

同一视线速度 \(v\) 引起：

\[
f_{d,\mathrm{carr}} \approx f_L \frac{v}{c},\quad
f_{d,\mathrm{code}} \approx f_{\mathrm{code}} \frac{v}{c}
\quad\Rightarrow\quad
f_{d,\mathrm{code}} \approx f_{d,\mathrm{carr}}\cdot\frac{f_{\mathrm{code}}}{f_L}
\]

对本工程 B2a：

| 量 | 设置字段 | 约值 |
|----|----------|------|
| \(f_L\) | `settings.carrFreqBasis` | 1176.45e6 Hz |
| \(f_{\mathrm{code}}\) | `settings.codeFreqBasis` | 10.23e6 Hz |
| 比例 | `codeFreqBasis / carrFreqBasis` | **≈ 1/115** |

例：\(f_{d,\mathrm{carr}}=-1329\,\mathrm{Hz}\) → 码多普勒 ≈ **−11.6 Hz**（此前 DLL 单独硬扛）。

---

## 3. 现状（代码）

`trackOneChannel.m`（及 monolit 的 `tracking2_v6_fix2`）DLL 更新：

```matlab
codeNco = ...;   % 2nd-order DLL, SoftGNSS 形式
codeFreq = ch.codeFreq - codeNco;   % ch.codeFreq ≡ codeFreqBasis
```

- **无** 载波项  
- `ch.codeFreq` 在 preRun 钉死为 `codeFreqBasis`  
- PLL/FLL 只更新 `carrFreq` / `carrFreqBasis`  
- pull-in 切换：`usePullinFilters()` → DLL 10 Hz / 2 Hz（保留）

---

## 4. 推荐实现形式

### 4.1 公式（与现有符号兼容）

当前符号约定（保持不动）：

```text
carrFreq      = 载波 NCO（用于相关 wipe-off）
codeNco       = DLL 滤波器输出（SoftGNSS 习惯：正 codeError → 减 codeFreq）
codeFreq      = 下一毫秒相关用的码率
```

建议更新为：

```matlab
% 载波辅助码多普勒（Hz）
carrAidCodeHz = carrFreq * (settings.codeFreqBasis / settings.carrFreqBasis);

% 码 NCO = 标称码率 + 载波辅助 − DLL 修正
codeFreq = settings.codeFreqBasis + carrAidCodeHz - codeNco;
```

注意：

1. **`carrFreq` 用本毫秒相关后、PLL/FLL 更新后的值**（与当前 DLL 块在 PLL 之后一致）——已是闭环估计，可直接辅助。  
2. 第一毫秒：`carrFreq = acquiredFreq`，辅助从捕获多普勒起步，合理。  
3. 若坚持用“基带频率”定义：`acquiredFreq` 已是 IF 域多普勒（本工程 ZeroIF），与 `carrFreq` 同一套，**不要**再减 `settings.IF`（IF=0）。  
4. REACQ 成功后重置：`codeFreq = codeFreqBasis + acquiredFreq * ratio`（与 `carrFreq` 重置同步）。

### 4.2 可选开关（配置）

```matlab
settings.carrierAidCode = true;   % default ON after validation
```

关闭时退回旧式 `codeFreq = codeFreqBasis - codeNco`，便于 A/B。

### 4.3 与 pull-in 策略关系

| 阶段 | DLL Bn | 载波辅助 |
|------|--------|----------|
| pull-in（`T_init < filter_pullinMS`） | 10 Hz | **开**（减轻高多普勒） |
| 稳态 | 2 Hz | **开** |

辅助打开后，稳态 2 Hz 更合理；**本轮不强制改 Bn**，只加辅助。

---

## 5. 修改文件清单

| 文件 | 改动 |
|------|------|
| `config/initSettings.m` | `carrierAidCode` 默认 true；注释比例 |
| `tracking/trackOneChannel.m` | DLL 更新公式 + REACQ 重置 |
| `tracking/tracking2_v6_fix2.m` | **仅** monolit 分支副本需同步（master / mexBaseFast） |
| `docs/plan_carrier_aided_code.md` | 本计划；实现后补验证结果 |

**不改：** `correlateB2aMs` / MEX（只消费 `codeFreq`）、NH 状态机、捕获。

---

## 6. 实现步骤（建议顺序）

1. **配置**  
   - `settings.carrierAidCode = true`  
   - 预计算 `codeCarrRatio = codeFreqBasis / carrFreqBasis`（避免每 ms 除法，可选）

2. **trackOneChannel 单点替换**  
   - 在 `codeNco` 算完后改 `codeFreq` 赋值  
   - REACQ 重置 `codeFreq` 时同样加辅助项  

3. **符号自检（桌面 1 分钟）**  
   - 固定 `carrFreq = +1000`、`codeNco = 0` → `codeFreq − f0 ≈ +1000/115 ≈ +8.7 Hz`  
   - 与开环相关：若符号反了，功率会掉 → 翻转 `+`/`-` 一次即可  

4. **同步 monolit**  
   - 把同一三行逻辑贴到 `tracking2_v6_fix2.m`（master / mexBaseFast）  

5. **验证冒烟**  

| 用例 | 期望 |
|------|------|
| PRN 41 / 24，5 s | LONG% 与现在相当，不回归 |
| PRN 23/25/27/32，5 s | 仍 LONG；`codeFreq−f0` 应贴近 `carrFreq * ratio`，\|dllDiscr\| 均值更小 |
| 关 `carrierAidCode` | 行为回到改前 |
| 可选：60 s 全星 | LONG 维持；为后续 PVT 稳态打底 |

6. **提交三分支**  
   - 先 `par-fast-matlab`，再 port master / mexBaseFast  

---

## 7. 风险与注意点

| 风险 | 缓解 |
|------|------|
| 辅助符号与 wipe-off 约定不一致 | 桌面符号自检 + 单星 5 s 功率对比 |
| PLL 短暂发散时码也被带偏 | 可选：辅助用 `carrFreqBasis`（慢变量）或限幅 `maxAidHz`；首版先用 `carrFreq` |
| FLL 大修正瞬间 | 与现网一致；限幅可后加 |
| `ch.codeFreq` 字段语义 | 保持 `ch.codeFreq = codeFreqBasis` 为“标称”，运行态只用局部 `codeFreq` |

---

## 8. 验收标准

1. 配置可开关，默认开启后无破坏 41/24 冒烟  
2. 问题星 5 s：LONG 成功；稳态段 `mean|dllDiscr|` 相对无辅助明显下降（目标：不再长期饱和在 0.5–0.9）  
3. 日志 `codeFreq` 与 `carrFreq * code/L` 在 LONG 段相关性高（散点近似斜率 1）  
4. master / mexBaseFast / par-fast 行为一致（串行路径）  

---

## 9. 工作量估计

| 项 | 估计 |
|----|------|
| 改码 + 配置 | ~0.5–1 h |
| 符号自检 + 4+2 星 5 s 冒烟 | ~0.5–1 h |
| 三分支同步 + 提交 | ~0.5 h |
| **合计** | **约半天内可完成** |

---

## 10. 建议决策点（实现前确认）

1. **默认开关：** 默认 `true`（推荐）还是先 `false` 仅试验？  
2. **辅助用哪个载波频率：**  
   - A. `carrFreq`（含瞬时 NCO，跟得紧）— **推荐首版**  
   - B. `carrFreqBasis`（FLL/PLL 积分基座，更平滑）  
3. **是否加辅助限幅**（如 \|aid\| ≤ 50 Hz）— 首版可不加  

确认后可直接按第 6 节落地实现。
