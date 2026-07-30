# PVT 审计报告（全星 60 s 结果）

**数据：** `results/smoke/fullsky_pvt60_260730_173603/`  
**分支：** `par-fast-matlab`  
**日期：** 2026-07-30  

---

## 1. 现象回顾

| 阶段 | 结果 |
|------|------|
| 跟踪 8 星 × 60 s | LONG% 87–95%，C/N0 42–51 dB-Hz |
| 星历 B-CNAV2 | **8/8** 解出 |
| 原 PVT | ECEF \|r\|≈**42114 km**，地球半径门限全灭，`nFixes=0` |

---

## 2. 检查项与发现

### 2.1 伪距 / `localTime`（`calculatePseudoranges`）

```text
startOffset = 68.802 ms
localTime(1) − max(transmitTime) = 0.068802 s  ✓ 与 startOffset 一致
rawP 量级：MEO ~20–24e3 km，IGSO ~34–35e3 km  ✓ 合理
epoch 内 rawP 散布 ~14300 km  ✓ 与 MEO+IGSO 混合一致
```

**结论：** 伪距构造与 SoftGNSS 相对伪距逻辑一致，**不是“伪距全乱”**。  
绝对尺由 `startOffset` 近似，公共钟差由 LS 的 `dt` 吸收。

**次要问题：**

- 首历元 `postNavigation` 强制 `dt=0` 且仅在 `fixValid` 时才用钟差回写 `localTime`；原先因地球半径门限失败，**钟差闭环从未生效**（鸡生蛋）。修复 satpos 后已能回写。
- 跟踪 `Timestamp(1)` 与导航 `transmitTime` 有约 **+1.07 s** 系统差（全星相同量级）→ 公共偏差，主要吃进钟差，不是主因。

### 2.2 星历 / `satpos1`（主因）

| PRN | 解码 SatType | 修复前 \|r_sat\| | 修复后 \|r_sat\| | 应有量级 |
|----:|:------------:|-----------------:|-----------------:|----------|
| 41 等 MEO | MEO | ~27900 km | ~27900 km | ~27900 km |
| **38** | **IGSO** | **~27857 km** | **~42090 km** | ~42160 km |
| **39** | **IGSO** | **~27975 km** | **~42266 km** | ~42160 km |

**根因（代码）：** `navigation/satpos1.m` 中按 `SatType` 选择 `A_REF` 的分支被**整段注释掉**，**一律使用 MEO 参考半长轴** `A_REF_MEO=27906100`。

```matlab
% 原错误逻辑（等价于）：
A_REF = A_REF_MEO;   % IGSO/GEO 也被当成 MEO
```

后果：

- IGSO 星（38/39）位置矮了约 **14 000 km**  
- 伪距仍是真实 IGSO 距离（~35 000 km）  
- 观测与星历几何严重矛盾 → LS 漂到 \|r\|≈**42 000 km** 的假解  

`satpos.m` 里 `strcmp` 分支是正确的，但 **`postNavigation` 调用的是 `satpos1`**。

### 2.3 GEO/IGSO/MEO 混合

- 本数据：**6 MEO + 2 IGSO**，无 GEO  
- 混合本身合理；在 **satpos 正确** 后，8 星 LS 可落在地球上  
- 修复前“像 GEO 半径”是 **IGSO 半长轴被算成 MEO** 的连锁反应，不是“不该混用 IGSO”

### 2.4 修复后重导航（同一套 trackResults）

| 指标 | 修复前 | **satpos1 修复后** |
|------|--------|-------------------|
| 有效地球半径历元 | 0/117 | **117/117** |
| 平均 \|r\|_ECEF | 42114 km | **6247 km** |
| 平均 lat/lon | NaN | **39.51°N / 116.94°E**（华北/北京一带） |
| 平均 height | NaN | **约 −123 km**（绝对高程仍偏） |
| ENU 起伏 | N/A | 仍很大（std 数十 km 级） |

**说明：** 绝对水平位置已合理（实验数据地在北京附近）；**高程与历元间 ENU 仍不稳定**，还需后续收紧钟差/伪距绝对尺/对流层等，但已跨过“解在地球上”的门槛。

---

## 3. 已做代码修改

**文件：** `navigation/satpos1.m`  

按 `eph.SatType` 选择：

- `MEO`（默认）→ `A_REF_MEO`  
- `IGSO` / `GEO` → `A_REF_IGSO_GEO`  

---

## 4. 建议的后续（按优先级）

| 优先级 | 内容 |
|-------:|------|
| P0 | 将 `satpos1` 修复同步到 **master / mexBaseFast** |
| P1 | 首历元也应用 `xyzdt(4)` 修正 `localTime`（不要 `dt=0` 钉死） |
| P1 | 核对 `Timestamp` 与 `TOW/subFrameStart` 的 **1.07 s** 系统差来源 |
| P2 | 高程偏差：`startOffset`、对流层、BDT 组延迟 |
| P2 | 历元 ENU 抖：elev mask、IGSO 权重、outlier 剔除 |

---

## 5. 一句话（给不熟 PVT 的读者）

跟踪和星历其实已经够用了。定位算飞，是因为算卫星坐标时 **把两颗 IGSO 当成了 MEO 高度**，伪距还按真 IGSO 距离来，几何对不上，最小二乘就漂到天上。修好半长轴参考后，解回到地球、落在北京附近；高程和抖动还可以再打磨。
