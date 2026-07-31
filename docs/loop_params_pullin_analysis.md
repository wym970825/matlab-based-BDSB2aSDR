# 无 FLL 时载波环 / 码环参数是否合适（pull-in 视角）

**范围：** `FLL.enable=0` 时实际生效的 PLL/DLL 配置与理论牵引入口  
**依据：** `initSettings.m`、`NH_stateMachine`、`channelCtrl/private/calcLoopCoef_NHSM.m`、`trackOneChannel` DLL 公式，以及 25/27/32/23 的 5 s FLLoff 冒烟。

---

## 1. 结论摘要

| 环节 | 配置意图 | 实际观感 | 判断 |
|------|----------|----------|------|
| PLL 前 2 s | Bn=50 Hz（“pull”） | 比稳定段宽 | **方向对**（先松后紧），数值中等偏激进，**不算“特别松”** |
| PLL 2 s 后 | Bn=30 Hz | 收紧 | 合理 |
| PLL 阶数 | 全程 3 阶 | 无 2 阶 pull-in | **对纯 PLL 牵引偏凶**；书上 pull-in 常用 2 阶 + 更宽 Bn 或 FLL |
| DLL | Bn=2 Hz 全程不变 | 跟踪带宽，不是牵引带宽 | **对 pull-in 偏紧**；且无载波辅助码 |
| 时间表 | pull 2 s → init 至 3 s → ESTI/LONG | 参数名易混 | `pllNoiseBandwidth_init` **从未被用到** |

结合 FLLoff 数据：问题星 **P0 仍强、14–100 ms 就塌**，比“带宽差一点点”更像 **DLL 饱和 + 无码多普勒辅助 + 3 阶 Costas 在噪声下乱推频率**。环路“抄书”本身 **没有松到能扛高多普勒/无 FLL 牵引**，但也 **不是简单的“稳跟带宽抄成了 2 Hz 当 pull-in”那种明显笔误**——PLL 牵引段确实是 50 Hz。

---

## 2. 配置从哪里来、真正用到了什么

### 2.1 `initSettings` 里写了什么

```text
DLL:  Bn=2 Hz, ζ=0.707, d=0.5 chip
PLL:  order=3
      pllNoiseBandwidth_pull = 50   ← 前 filter_pullinMS 用
      pllNoiseBandwidth_stab = 30   ← 之后 / LONG 用
      pllNoiseBandwidth_init = 50   ← 未接线
      pllNoiseBandwidth      = 30   ← 遗留字段，NHSM 不用
      filter_pullinMS = 2000
      trackInit_MS    = 3000
      longCoh_ms      = 1
```

### 2.2 NH 状态机如何选 `pf`（INIT、无 FLL）

```text
T_init < 2000 ms  →  pf_pull  (Bn=50, T=1 ms)
T_init ≥ 2000 ms  →  pf_init  (Bn=30, T=1 ms)   // 名字像 init，实际吃的是 stab 带宽
T_init ≥ 3000 ms  →  尝试 ESTI→LONG
LONG              →  pf_long  (Bn=30, T=longCoh_ms=1 ms → 与 1 ms 稳定几乎相同)
```

命名容易误会：

- 代码里 **`pf_pull` = 更宽**，**`pf_init` = 更窄（stab）**  
- 设置项 **`pllNoiseBandwidth_init` 完全没进 NHSM**  
- 阻尼 `pllDampingRatio_*` 对 **3 阶** 也不进公式（3 阶用固定 a3=1.1, b3=2.4）

### 2.3 系数公式：两套 `calcLoopCoef_NHSM` 并存

| 文件 | 谁在用 | 3 阶 Wn |
|------|--------|---------|
| `channelCtrl/private/calcLoopCoef_NHSM.m` | **NH_stateMachine 实际调用** | `Wn = BW/0.7845`（与 SoftGNSS/`calcLoopCoefCarr` 一致） |
| `channelCtrl/calcLoopCoef_NHSM.m` | path 上直接 `calcLoopCoef_NHSM(...)` | `Wn = 2π·BW/0.7845`（**约 6.28 倍更猛**） |

运行时实测（private 版）：

```text
pf_pull (Bn=50): [152.96, 4.468, 0.259]
pf_init (Bn=30): [ 91.78, 1.609, 0.056]
pf_long (Bn=30): 同上
```

若误用 public 的 2π 版，pf1 会到 ~960（Bn=50），那才是“极紧/极猛”。**当前跟踪没有踩那个坑。**

---

## 3. 载波环（无 FLL）理论是否够松

### 3.1 离散 3 阶更新（`trackOneChannel` INIT）

每 1 ms、Costas 相位误差（cycle）进滤波器：

```text
d2 += e * pf3
d1 += d2 + e * pf2
NCO = d1 + e * pf1
carrFreq = carrFreqBasis + NCO
```

鉴相：INIT 用 **pilot prompt + costas 半周折叠**，**不做 Weil wipe**（NH 当数据比特翻，Costas 理论上可扛）。

### 3.2 带宽“松/紧”对照（经验量级）

| 场景 | 常见 Bn（1 ms 更新） | 本工程 |
|------|----------------------|--------|
| 精跟 / 稳态 PLL | 10–25 Hz | LONG 名义 30 Hz |
| Pull-in / 较松 PLL | 30–50+ Hz，或 2 阶 | 前 2 s：**50 Hz、3 阶** |
| 无 FLL、仅靠 PLL 吃大频差 | 往往不够，要 FLL 或更宽 2 阶 | FLL 关后只靠 3 阶 Costas |

**判断：**

- 相对稳态 30 Hz，前 2 s 的 **50 Hz 算“略松”**，符合“牵引时 loosen”的方向。  
- 但相对 **无 FLL 的纯 PLL 牵引**，50 Hz **3 阶** 并不算松：  
  - 3 阶对频率斜坡/噪声更敏感；  
  - 鉴相增益在失锁/低 CN0 时偏离设计，宽环 + 3 阶更容易 **把频率推飞**（FLLoff 里 25 号 200 ms 内 dCarr≈−167 Hz 符合这种形态）。  
- 书上 SoftGNSS 经典是 **2 阶 + 约 25 Hz** 一类；你抄的 3 阶 50/30 更接近“稳态/半牵引”，**不是“很松的 pull-in 专用组”**。

### 3.3 与捕获残差的匹配

精捕后频差通常已在 **数 Hz～十几 Hz** 量级（细搜 2 Hz 步进）。  
对这类残差，**Bn=50 的 PLL 足够锁住**——若鉴相干净。  
问题星 **开环 20 ms 功率正常**，说明起始频点可用；崩在闭环，更指向 **鉴相/环路动态**，而不是“Bn 设成 2 Hz 太紧锁不进去”。

---

## 4. 码环理论是否够松

### 4.1 当前 DLL（SoftGNSS 公式）

```text
Bn = 2 Hz, ζ = 0.707, k = 1
Wn ≈ 3.77, τ1 ≈ 0.070, τ2 ≈ 0.375
codeFreq = codeFreqBasis − codeNco     // 无载波辅助
E–L 间距 0.5 chip
```

这是典型 **跟踪带宽**，不是 pull-in 带宽。

粗算建立时间 ~4/Wn ≈ **1 s 量级** 才谈得上慢收敛；  
而问题星 **14–25 ms 就 firstWeak**，时间尺度上 **更不像“DLL 太紧收敛慢”**，更像 **鉴相饱和/码相位系统偏差 + 载波被 PLL 推走后相关峰滑掉**。

### 4.2 码多普勒需求（无载波辅助时全靠 DLL）

| 星 | \|fd\| Hz | 约码多普勒 Hz | chips/ms |
|----|----------:|--------------:|---------:|
| 41（稳） | 276 | 2.4 | 0.002 |
| 24（稳） | 796 | 6.9 | 0.007 |
| 25 | 1329 | **11.6** | 0.012 |
| 32 | 1474 | **12.8** | 0.013 |
| 27 | 1625 | **14.1** | 0.014 |
| 23 | 2491 | **21.7** | 0.022 |

2 阶 DLL 理论上能消掉 **常值码频差**（零稳态误差），但：

- 瞬态要时间，且 **E–L 一旦饱和（数据里 dll≈−0.6~−0.9）** 就不再是线性设计；  
- **没有 `codeFreq += carrFreq * f_code/f_L`**，高多普勒星从第一毫秒就靠 DLL 硬扛 10–20 Hz 码频偏。

稳星 fd 小，DLL Bn=2 够用；问题星 fd 大，**同样 Bn 更吃力**——这与“只跟死 4 星”一致。

### 4.3 pull-in 是否该 loosen DLL？

理论/工程上 **应该**：

| 阶段 | DLL Bn 建议量级 |
|------|-----------------|
| Pull-in | 5–15 Hz（甚至短时 20） |
| 稳态 | 0.5–2 Hz |

你现在 **全程 2 Hz** → 对 pull-in **偏紧**；对稳态合理。

---

## 5. “随便抄书”常见偏差对照

| 书上常见 | 你现在 | 评价 |
|----------|--------|------|
| Pull-in 用更宽 PLL | 50 vs 30 | 有，但只宽一档 |
| Pull-in 用 2 阶 | 全程 3 阶 | **偏猛** |
| DLL pull-in 加宽 | 无 | **缺** |
| 载波辅助码 | 无 | **缺（高多普勒关键）** |
| FLL 协助大频差 | 默认开，关了更难 | 关 FLL 后 3 阶 PLL 单独扛 |
| 相干加长再收窄 | longCoh_ms=1 | LONG 与 1 ms 稳定几乎无差别 |

所以更准确的说法是：

> 不是“稳跟参数抄成了牵引参数”，而是 **牵引只比稳态略宽一点，阶数仍 3，码环完全没进入牵引模式**；再叠加 **无 FLL / 无码辅助**，高多普勒问题星最先死。

---

## 6. 和 FLLoff 实测怎么对得上

| 现象 | 与参数关系 |
|------|------------|
| 关 FLL 与开 FLL 一样挂 | 主因不在 FLL 增益，在 **PLL+DLL 本体** |
| P0 大、很快塌 | 起始点 OK；**闭环动态**有问题 |
| dll 饱和 ~−0.7 | 线性 DLL 设计失效；**不是“再松 1 Hz 就好”这么简单**，但 **松 DLL + 载波辅助** 仍是优先试验 |
| dCarr 百 Hz 级漂移（无 FLL） | 3 阶 Costas 在失配/噪声下 **推频**，Bn=50 **帮凶而不是救命** |

---

## 7. 若要按“牵引宜松”改，建议试验梯度（仅建议，未改代码）

**P0（最值得试）**

1. **载波辅助码**（与 Bn 无关，先修物理通道）  
   `codeFreq = f0 + carrFreq*(f0/fL) - codeNco`（符号与现有 NCO 约定对齐后测）
2. **Pull-in DLL**：前 1–2 s Bn=8~12 Hz，之后回 2 Hz  
3. **Pull-in PLL**：前 1–2 s **2 阶 + Bn=40~60**，再切 3 阶 Bn=25~30  

**P1**

4. 把 `pllNoiseBandwidth_init` 真正接到“最松一段”，或改名避免死配置  
5. 统一只保留 **private** 版 `calcLoopCoef_NHSM`，删掉/修正 public 2π 版，防后人踩坑  
6. `longCoh_ms` 在 LONG 真正 >1 时再收窄 Bn  

**不建议一上来就做的**

- 把 3 阶 Bn 拉到 100+ 且无 FLL：更容易噪声推飞  
- 只把稳态 Bn 改松：救不了 20 ms 内的 pull-in  

---

## 8. 一句话

**无 FLL 时：载波环牵引段（50 Hz）只是“略松”，阶数仍偏激进；码环（2 Hz、无辅助）对 pull-in 明显偏紧。**  
更不像“抄得太松”，而像 **“稳态味的参数 + 略宽 PLL”在高多普勒、无 FLL 下不够用**；下一步优先 **码辅助 + 分阶段加宽 DLL/改 2 阶 pull-in PLL**，而不是继续纠结 FLL 开关。
