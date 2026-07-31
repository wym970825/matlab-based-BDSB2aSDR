# BDS-3 B2a 软件接收机 — 用户手册（面向 MATLAB 新手）

> 本文综合仓库内架构、捕获/跟踪/定位设计、可选算法与 Web UI 文档，写成**可读完就能上手**的说明。  
> 目标读者：会写 `cd`、改几个参数、跑通脚本，但还不熟悉 GNSS 软接收机内部流程。  
> 当前工程版本约 **v0.1.6**；路径默认 `F:\matlab-GNSSsdr\BDS\B2a`。

---

## 0. 你在做什么：一句话与一张图

这个项目是一台**离线软件 GNSS 接收机**：读一段已经录好的 BDS B2a 中频（IF）数据，按顺序做

**捕获 → 跟踪 → 电文解算 → 伪距与定位 → 画图 / 导出 NMEA / 百度地图**。

它不负责“实时天线采样”，只负责把磁盘上的 `*.bin` 变成位置、轨迹和诊断结果。

```
  ┌────────────┐     ┌────────────┐     ┌──────────────┐     ┌────────────┐
  │  IF 文件   │ ──► │   捕获     │ ──► │    跟踪      │ ──► │  定位 PVT  │
  │ (20 MHz IQ)│     │ 谁在、粗频 │     │ 码/载波环    │     │ 伪距+LS   │
  └────────────┘     │ 粗码相位   │     │ 比特流 I_P   │     │ 经纬高     │
                     └────────────┘     └──────────────┘     └────────────┘
                            │                   │                   │
                            ▼                   ▼                   ▼
                       channel 结构      TrackResults2[]      navSolutions
                       (交接给跟踪)       (1 ms 日志)         (历元解)
```

三个阶段共享同一套配置结构体 `settings`（`config/initSettings.m`），但**彼此依赖的数据不同**：

| 阶段 | 主要输入 | 主要输出 | 失败时后面会怎样 |
|------|----------|----------|------------------|
| 捕获 | IF 文件、PRN 列表 | 每星多普勒、码相位、Weil 相位等 | 无星 → 整条链路停 |
| 跟踪 | 捕获交接 + IF | 每毫秒相关值、`I_P` 比特、C/N0 | 不够长 / 失锁 → 解不出电文 |
| 定位 | 跟踪结果 | 伪距、ECEF/LLA、DOP、NMEA | 可见星 \<4 或无星历 → 无解 |

读文档时记住：**先搞清楚“这一阶段吃什么、吐什么”**，再去调参数，会省很多弯路。

---

## 1. 环境与第一次跑通

### 1.1 你需要准备什么

1. **MATLAB**（建议 R2020b 及以上；作者环境常用 R2024b）。Mapping Toolbox 有则地图更漂亮，没有也能用平面经纬度回退。  
2. **一段 B2a IF 数据**（默认示例在配置里写死了路径，请改成你自己的）：  
   - 采样率常见 **20 MHz**，**IQ 交织 int16**，中频 **0**（零中频）。  
3. （可选）**Python 3.9+**：只跑 Web 界面时需要；**不需要**安装 MATLAB Engine。  
4. （可选）百度地图浏览器 AK：写在 `config/BaidumapKey.txt`（仓库有 `BaidumapKey.example.txt` 作模板）。

### 1.2 推荐的两种上手路径

**路径 A — Web 界面（少碰 MATLAB 桌面）**

```text
cd F:\matlab-GNSSsdr\BDS\B2a
python launch_b2a_ui.py
```

浏览器打开 http://127.0.0.1:8787 ，按 Tab 改「数据 / 捕获 / 跟踪 / 定位 / 显示」，点**运行全流程**。  
Python 会自动找本机 `matlab.exe`，用**干净环境** `-batch` 调用 `runFromJsonConfig`（避免从 Python 继承 `PYTHON*` 导致启动崩溃）。  
结果在 `results/ui/<任务号>/`。

**路径 B — 纯 MATLAB（便于调试、改一行看效果）**

```matlab
cd('F:\matlab-GNSSsdr\BDS\B2a')
setupPaths   % 把 core/ tracking/ navigation/ 等加进 path

% 最短冒烟：只看捕获能不能找到星
smokeA = smoke_acquisition('fullSky', false);   % 默认 PRN 列表，较快

% 单星跟踪 5 s（不定位）
smokeT = smoke_tracking('acqSatelliteList', smokeA.bestPrn, 'msToProcess', 5000);

% 完整链路（定位需要跟踪足够长，B-CNAV2 建议 ≥24 s，且最终至少 4 星有完整星历）
results = run_B2a('msToProcess', 60000, 'acqSatelliteList', [24 38 39 41]);
```

`setupPaths` 必须先跑，否则 `run_B2a`、`postNavigation` 会“找不到函数”。这是本项目的 path 约定，不是 MATLAB 自带路径。

### 1.3 第一次必改的三个配置

打开 `config/initSettings.m`（或 Web 的「数据」Tab），至少确认：

```matlab
settings.filePath = '...你的目录...';
settings.fileName = '...你的文件.bin';
settings.msToProcess = 60e3;              % 先短后长
settings.acqSatelliteList = [24 38 39 41]; % 已知强星，全空搜索用 1:60 很慢
```

采样率、数据类型若与文件不一致，捕获会“全是噪声峰”。默认约定：**20e6 Hz、int16、fileType=2（IQ）**。

### 1.4 成功长什么样

- 捕获：命令行出现若干 PRN 的 `carrFreq` 有限、峰度超过门限。  
- 跟踪：状态到 `LONG`，C/N0 大约稳定在 30–50 dB-Hz（数据相关）。  
- 定位：`navSolutions.latitude` 出现一串有限值；高度合理量级（例如几十米到百米级，视站址）。  
- 图：`plotNavPost` 给出 ENU、速度、DOP、地图；可选 `pvt.nmea` 与百度轨迹页。

---

## 2. 目录与模块关系（先建立地图）

```
B2a/
  setupPaths.m          路径
  config/initSettings.m 唯一主配置
  core/                 流水线编排（run_B2a, runAcquisition, runNavigation, runFromJsonConfig）
  acquisition/          捕获算法
  tracking/             跟踪调度 + 单星 trackOneChannel
  navigation/           电文、伪距、LS/RAIM、NMEA
  channelCtrl/          NH 状态机、TrackResults2、脉冲消隐、可选载波 KF
  signal/               B2a 扩频码 / Weil 生成
  include/              画图、preRun、百度地图启动
  common/               坐标、最小二乘、伪距
  tests/                smoke / 全空诊断
  web/ui + python/      Web 界面
  results/              输出（大 mat 一般不入库）
```

### 2.1 主链路调用关系

```
run_B2a / runFromJsonConfig
    │
    ├─ initSettings          ← 所有开关几乎都在这里（或 JSON 覆盖）
    ├─ openIfFile            ← 打开 IF
    ├─ runAcquisition
    │      └─ acquisition_robust_v2fft   (+ 可选 pulseBlanker)
    ├─ preRun2               ← 捕获结果 → channel[]
    ├─ tracking2_v6_fix2
    │      └─ trackOneChannel × N  (可 parfor)
    │             ├─ NH_stateMachine
    │             ├─ 相关 / DLL·PLL·FLL
    │             └─ TrackResults2 写日志
    ├─ runNavigation → postNavigation
    │      ├─ decodeEphWithReacqResync / BCNAV2decoding
    │      ├─ calculatePseudoranges
    │      ├─ satpos1
    │      ├─ leastSquarePos 或 raimLeastSquarePos
    │      └─ cart2geo / cart2utm
    ├─ exportNmea            ← 可选
    └─ plotNavPost / Baidu   ← 可选
```

### 2.2 历史坑（理解“为什么有 run_B2a”）

旧代码跟踪结果没正确返回，又在导航前 `load` 了别的 mat，导致**定位与本次跟踪脱节**。  
现在规定：**跟踪必须返回完整 `TrackResults2` 数组，导航只用这份活结果**。  
你日常只要走 `run_B2a` / Web UI，不要自己 `load` 来源不明的 `trackingResults_*.mat` 去导航。

---

## 3. 配置怎么想：一个结构体贯穿全程

`settings = initSettings(...)` 返回结构体。Name-Value 可覆盖常用字段：

```matlab
settings = initSettings( ...
    'filePath', 'D:\ifdata', ...
    'fileName', 'xxx.bin', ...
    'msToProcess', 120000, ...
    'acqSatelliteList', 1:60, ...
    'useParfor', true, ...
    'parMaxWorkers', 4);
```

嵌套算法块用子结构体，例如：

```matlab
settings.FLL.enable = true;
settings.raim.enable = true;
settings.lsWeight.enableElev = true;
settings.nmea.enable = true;
settings.carrierAidCode = true;
```

Web UI 的每个 Tab 对应一批字段，最终写成 JSON，由 `runFromJsonConfig` 合并进 `settings`。  
**原则：先用默认跑通，再只改你懂的开关**；一次改十个环路参数很难定位问题。

---

## 4. 捕获：在噪声里找到“哪颗星、粗频偏、粗码相位”

### 4.1 问题是什么

B2a 信号淹没在噪声里。捕获要回答：

1. 搜索列表里哪些 PRN 存在；  
2. 载波多普勒大约多少（反映相对运动与钟差）；  
3. 码相位（本地码与信号对齐的采样点）；  
4. Weil 副码相位与导频极性（交给跟踪做 NH 剥离）。

### 4.2 本工程怎么做（粗 + 精）

实现：`acquisition/acquisition_robust_v2fft.m`。

**粗捕获（约 1 ms 量级思路）**

- 生成本地 B2a **导频主码**（先不考虑副码）。  
- 在多普勒网格上做相关（PCPS / 相关搜索）；实现里用分段与多种 **flip 假设**，减轻副码边沿导致的相关峰被“抵消”。  
- 用峰度类指标（峰 / 均值）与 `acqThreshold` 比较是否判到。

**精捕获**

- 在粗多普勒附近，用多毫秒导频相干积分 refine 频率；  
- 估计 **Weil(100)** 起始相位；  
- 可选在小窗内 refine 码相位；  
- 输出 `polarityRef`，给 PLL 初相，减少半周模糊带来的拉入困难。

关键参数（`initSettings`）：

| 参数 | 含义 | 调参直觉 |
|------|------|----------|
| `acqSatelliteList` | 搜哪些 PRN | 新手用强星列表；`1:60` 全空很慢 |
| `acqSearchBand` | 多普勒单边搜索 Hz | 静置/短基线几千 Hz 通常够 |
| `acqStep` | 多普勒步进 | 越细越慢、越不易漏峰 |
| `acqThreshold` | 峰度门限 | 虚警多就抬高；漏检就略降（数据相关） |
| `fineNoncoh` | 精捕非相干积累 ms | 弱信号可略加，代价是时间 |

### 4.3 捕获与跟踪的交接

`preRun2` 把最强的一批捕获结果填进 `channel(i)`：`acquiredFreq`、`codePhase`、`weilPhase`、`polarityRef`、`status='T'`。  
跟踪**不是**重新瞎搜，而是从这些初值附近把环路合上。交接错了，后面 PLL 会一直抖。

### 4.4 你怎么单独练捕获

```matlab
smokeA = smoke_acquisition('fullSky', false);
% 看 smokeA 里 peakMetric、bestPrn
```

全空：`'fullSky', true`。诊断类脚本见 `tests/run_fullsky_*`。

---

## 5. 跟踪：把“粗对齐”收成连续观测量与比特流

### 5.1 问题是什么

捕获只有粗估计。跟踪在每个 1 ms（本工程默认 `intTime=0.001`）上：

- 用 **DLL** 维持码相位（伪距测量基础）；  
- 用 **PLL**（常配合 **FLL**）维持载波相位/频率；  
- 在导频上处理 **NH/Weil 副码**，使相关峰不因副码翻转而崩；  
- 在数据支路上积累 **I_P**，供 B-CNAV2 解电文；  
- 周期性估计 **C/N0**，过低则进入重捕获（REACQ）。

### 5.2 状态机：INIT → LONG，失锁 → REACQ

核心：`channelCtrl/NH_stateMachine.m`（由 `trackOneChannel` 驱动）。

```
          Weil 置信足够
   INIT ─────────────────► LONG（稳态跟踪，副码 wipe-off）
     │                         │
     │ C/N0 过低               │ C/N0 过低 / 周期重估
     ▼                         ▼
   REACQ ◄────────────────── ESTI（Weil 再估计，码/载波短暂 zero-hold）
```

- **INIT**：拉入阶段，环路带宽往往更宽（`*_pull`）。  
- **LONG**：稳态，带宽收窄（`*_stab`），更适合出定位观测量。  
- **FLL 子态**（`INIT_FLL` / `LONG_FLL`）：频率误差持续偏大时，频率环辅助压多普勒，减轻纯 PLL 失锁。  
- **REACQ**：失锁后的重捕等待/再捕获；本工程会给该毫秒打上 `trk_state=9`，并记录 `absoluteSample`，避免时间轴出现“空洞却假装在跟踪”。

### 5.3 1 ms 环内在干什么（概念顺序）

实现主文件：`tracking/trackOneChannel.m`（多星时由 `tracking2_v6_fix2` 串行或 parfor 调度）。

1. 从 IF 文件读 1 ms 样点；可选 **脉冲消隐 PB**（DME 类脉冲干扰）。  
2. 码 NCO 生成早/即时/迟相关（数据 + 导频）。  
3. 载波 wipe-off（相位连续）。  
4. 鉴相/鉴频：DLL（早减迟）、PLL（Costas / atan2）、可选 FLL。  
5. 环路滤波，更新 `codeFreq`、`carrFreq`。  
6. LONG 时对导频做 NH 剥离；缓冲做 Weil 估计。  
7. 每 `CNoInterval` ms 更新 C/N0。  
8. 写入 `TrackResults2`（分块落盘，长数据不至于一次吃光内存）。

### 5.4 环路带宽：拉入宽、稳态窄

```matlab
settings.dllNoiseBandwidth_pull = 10;  % Hz，拉入
settings.dllNoiseBandwidth_stab = 2;
settings.pllNoiseBandwidth_pull = 50;
settings.pllNoiseBandwidth_stab = 30;
settings.filter_pullinMS = 2000;       % 前 2 s 用 pull 带宽
settings.trackInit_MS    = 3000;       % INIT 阶段长度量级
```

直觉：带宽宽 → 跟得上动态、噪声大；窄 → 平滑但易失锁。新手不要先改这里，除非强星仍进不了 LONG。

### 5.5 可选算法：如何打开、各自解决什么问题

#### （1）FLL 辅助 PLL（默认开）

```matlab
settings.FLL.enable = true;
settings.FLL.aidingEnable = true;
```

- **做什么**：用频率鉴别器估计残余频差，滤波后辅助载波 NCO，减轻高动态或初捕频差时 PLL 单独硬扛。  
- **何时关**：对比实验、怀疑 FLL 引入异常时。  
- **相关文件**：`trackOneChannel` + `settings.FLL.*` 门限与增益。

#### （2）载波辅助码环（默认开，v0.1.2+）

```matlab
settings.carrierAidCode = true;
settings.carrierAidCodeMaxHz = 50;   % 码域限幅 Hz
```

- **做什么**：视线速度同时产生载波多普勒与码多普勒，二者近似成比例 \(f_{d,\mathrm{code}} \approx f_{d,\mathrm{carr}}\cdot f_{\mathrm{code}}/f_L\)（B2a 约 1/115）。把载波估计的多普勒按比例喂给码 NCO，DLL 只跟残差，高多普勒星更稳。  
- **注意**：符号与限幅曾专项修过；对比请用 `settings.carrierAidCode=false` 做对照，而不是只改限幅。  
- **实现**：`tracking/codeFreqFromCarrierAid.m`。

#### （3）脉冲消隐 PB（默认开）

```matlab
settings.EnablePB = true;
% PB_settings 阈值与 USRP scaleK/gain 标定有关
```

- **做什么**：检测到脉冲式强干扰样点时消隐，减轻相关器被冲垮。  
- **若数据很干净**：可关，略省算力；阈值不准时可能误消隐。

#### （4）载波卡尔曼 KF（默认关）

```matlab
settings.KF.enable = false;
settings.KF.enableFeedback = false;
```

- **做什么**：更复杂的载波状态估计（含闪烁自适应等钩子）。  
- **新手**：保持关闭；先掌握 DLL/PLL/FLL 基线。

#### （5）多星并行 parfor（par-fast 分支，默认倾向开）

```matlab
settings.useParfor = true;
settings.parMaxWorkers = 4;   % 硬顶 6
```

- **做什么**：每颗星在 worker 上**私有 fopen** 同一 IF，避免共享文件句柄竞争。  
- **关掉**：`useParfor=false` 便于单步调试。  
- **预期**：星数多、CPU 够时接近 `min(星数, workers)` 倍；磁盘瓶颈时加速有限。

#### （6）重捕获 REACQ

```matlab
settings.REACQ_max = 5;
settings.TrkCN0Th  = 25;   % 与失锁判决相关
settings.CNo_Th    = 30;
```

- 跟踪中 C/N0 过低进入 REACQ；成功后重新 INIT 副码/帧同步。  
- **定位侧**必须认识 REACQ：旧 TOW 不能跨失锁硬用（见下一章）。

### 5.6 跟踪结果你要认识的字段

| 字段 | 用途 |
|------|------|
| `I_P` | 数据支路即时支路，电文比特来源 |
| `absoluteSample` | 该 ms 对应 IF 样点索引，伪距时间轴 |
| `codeFreq` / `carrFreq` | 环路频率 |
| `B2a_CNo` | C/N0（按 `CNoInterval` 抽样） |
| `trk_state` | 含 REACQ=9 等，导航会跳过无效点 |
| `status` | `'T'` 跟踪 / `'-'` 无效 |

---

## 6. 定位：从比特与码相位到经纬高

### 6.1 需要满足的硬条件

1. 跟踪足够长，便于解出 B-CNAV2：类型 **10、11** 与 **30–34 之一**（工程上常按 **≥24 s** 准备）。  
2. 同一时段内，**至少 4 颗星**同时有有效伪距与星历。  
3. `I_P`、`absoluteSample` 完整可信。

入口：`runNavigation` → `postNavigation`。

### 6.2 处理流水（逻辑顺序）

```
每颗星:
  I_P ──BCNAV2decoding──► 星历 eph + 子帧起点 + TOW
         │
         │  (若中途 REACQ：按 lock 段切开，多段 TOW)
         ▼
历元循环 (navSolPeriod，默认 500 ms):
  选该历元 absoluteSample 附近的码相位
  用对应 TOW 段算发射时间 transmitTime
  伪距 ≈ (localTime - transmitTime) * c
  satpos1(发射时间, eph) → 卫星 ECEF
  最小二乘 / RAIM → 接收机位置 + 钟差
  cart2geo → 纬度经度高程
```

### 6.3 伪距在说什么

接收机本地时间与卫星发射时间之差 × 光速，得到**含钟差的伪距**。  
四颗星以上才能同时估 **三维位置 + 接收机钟差**。  
本工程 `calculatePseudoranges` 会：

- 跳过 `absoluteSample` 非有限或 `trk_state==9` 的点；  
- 按**当前历元落在哪一段 lock** 选择 TOW（多段 TOW，见下）。

### 6.4 多段 TOW：REACQ 之后为什么不能只用“第一个前导”

失锁再捕获后，码相位与帧起点都变了。若整条 track 仍用**第一次**解出的 `(subFrameStart, TOW)`，发射时间会错，伪距可跳**数十万公里**。

当前策略（v0.1.5+）：

1. `decodeEphWithReacqResync` 按 REACQ 把每星切成多段，段内各自解码 TOW；  
2. 每个历元用该星**当前段**的 TOW；  
3. 导航时间窗从**最早可用段**起算，而不是“全局最后一次 REACQ 之后才开始”；  
4. **每个历元**只要有效星 ≥4 就尝试 LS（中间某星 REACQ 只丢掉该星）。

集体失锁后若连续多个历元解不出，会重置 `localTime`，避免钟差继承错乱。

对照：`docs/ls_weight_multitow.md`、`docs/reacq_framesync_absample.md`。

### 6.5 最小二乘定位与可选加权

默认：`leastSquarePos` 等权迭代 LS + 可选对流层改正（`useTropCorr`）。

**高度角 / 载噪比加权（默认关）**：

```matlab
settings.lsWeight.enableElev = true;   % w ∝ sin(el)^elevExp
settings.lsWeight.enableCno  = true;   % w ∝ 10^((C/N0-ref)/10)
settings.lsWeight.wMin = 0.05;         % 下限，避免弱星权重≈0
settings.lsWeight.wMax = 1.0;
```

- 低仰角、低 C/N0 观测噪声通常更大，降权可压野值影响。  
- 残差仍以**米**上报，便于和 RAIM 门限同一量纲。

### 6.6 RAIM / FDE（默认开）

```matlab
settings.raim.enable     = true;
settings.raim.enableFde1 = true;  % 单星剔除，需 n≥5
settings.raim.enableFde2 = true;  % 双星剔除，需 n≥6
settings.raim.maxRmsM    = 80;
settings.raim.maxResM    = 200;
```

- **做什么**：全星 LS 后看残差；不通过则尝试剔 1～2 颗星再解，选通过门限且分数最好的子集。  
- **典型收益**：单星伪距跳变导致高度飞到百公里时，剔除后回到合理高度。  
- **关掉**：`settings.raim.enable=false` 做对比。  
- 详见 `docs/raim_fde.md`。

### 6.7 历元间隔与高度角掩码

```matlab
settings.navSolPeriod  = 500;  % ms，定位输出率
settings.elevationMask = 5;    % 度，过低仰角可不参与
```

### 6.8 只重跑定位（不重跟踪）

跟踪很贵。若已有 `results.mat` 里的 `trackResults`：

```matlab
S = load('results/smoke/..../results.mat');
tr = S.report.trackResults;   % 字段名以实际为准
if ~isstruct(tr), tr = trackResultsToStruct(tr); end
settings = initSettings('msToProcess', 280000);
% 在这里改 raim / lsWeight / nmea 等
[nav, eph] = postNavigation(tr, settings);
plotNavPost(nav, settings, 'saveDir', 'results/smoke/renav_figs');
```

**注意**：若旧 mat 在 REACQ 毫秒没有正确的 `absoluteSample`，多段 TOW 仍吃亏，需要**重新跟踪**才能吃到完整修复。

---

## 7. 输出：图、NMEA、百度地图

### 7.1 MATLAB 图 `plotNavPost`

默认 `settings.plotNavPost = true`。在时间序汇总有效历元后：

1. ENU 位移（相对均值或 `truePosition`）  
2. ENU 速度  
3. GDOP / HDOP / VDOP  
4. 天空图  
5. `geobasemap('streets-light')` 轨迹（时间热力 + 起终点）

航迹会去掉 ENU 任一方向速度 **> `navTrackMaxSpeedMps`（默认 500 m/s）** 的跳变点，减轻显示被野值拉飞。

静默：`settings.plotNavPost = false` 或 `plotNavPost(..., 'silent', true)`。

### 7.2 NMEA（GGA + GSV）

```matlab
settings.nmea.enable = true;
settings.nmea.talkerId = 'GB';   % 北斗 Talker，亦可用 BD/GN
exportNmea(navSolutions, settings, 'trackResults', trackResults, 'outDir', outDir);
```

- **GGA**：时间、经纬、质量、星数、HDOP、高程。  
- **GSV**：可见星 PRN、仰角、方位、SNR（来自 `B2a_CNo`）。  
- 时间由 BDT 尺度 SOW 减 `bdtMinusUtc`（默认 4 s）得到 UTC 日内时。  
详见 `docs/nmea_export.md`。

### 7.3 百度地图

```matlab
settings.plotBaiduMap = true;
launchBaiduMapTrack(navSolutions, settings, 'outDir', figDir);
```

WGS84 → BD-09 后画轨迹；**必须用** `http://127.0.0.1:...` 打开（`file://` 底图常空白）。AK 放 `config/BaidumapKey.txt`。

---

## 8. 推荐学习顺序（练习任务）

| 步骤 | 做什么 | 你应搞懂 |
|------|--------|----------|
| 1 | `setupPaths` + `smoke_acquisition` | 峰度、PRN、多普勒初值 |
| 2 | `smoke_tracking` 5–10 s 单星 | INIT/LONG、C/N0、相关图 |
| 3 | `run_B2a` 60 s、4 星列表 | 整链数据流 |
| 4 | 把 `msToProcess` 加到 ≥120 s | 为何电文要时长 |
| 5 | 开关 `carrierAidCode` / `FLL` 对照 | 可选算法体感 |
| 6 | 开关 `raim`、看高度野值 | FDE 何时救人 |
| 7 | 只 `postNavigation` 重跑 | 定位与跟踪耗时分离 |
| 8 | Web UI 跑同一配置 | JSON 与 settings 对应关系 |

---

## 9. 常见问题（按现象查）

**1）`Undefined function or variable`**  
未 `setupPaths`，或当前目录不在工程根。

**2）捕获一颗都没有**  
IF 路径/采样率/IQ 类型错；门限过高；PRN 列表不含可见星；数据段本身无信号。

**3）跟踪 C/N0 很低或一直 REACQ**  
捕获交接差；PB 阈值误伤；环路带宽极端；文件中途无信号。

**4）有跟踪但 `postNavigation` 退出**  
不足 24 s；解不出 10/11/30–34；有效星 \<4。先看命令行 “Message type … not decoded”。

**5）伪距/位置突然飞走**  
历史问题是 REACQ 后 TOW 未分段；请用当前多段 TOW 版本，并确认 track 含 REACQ 的 `absoluteSample`。可开 RAIM。

**6）Web 唤起 MATLAB Access Violation**  
多为 Python 环境变量污染。请用新版 `matlab_runner`（干净环境）；或设 `B2A_MATLAB`，关掉其它 MATLAB 再试。详见 `docs/web_ui_v016.md`。

**7）百度地图只有点和线没有底图**  
用本地 http 打开；检查 AK 与 Referer 白名单是否含 `127.0.0.1`。

**8）并行没有变快**  
`useParfor` 已关；星数 \<2；磁盘成为瓶颈；workers 被顶到 ≤6。

---

## 10. 分支与版本（你clone 时可能看到）

| 分支 | 含义 |
|------|------|
| `master` | 基线合入 |
| `mexBaseFast` | 相关/消隐等 MEX 加速路径 |
| `par-fast-matlab` | 多星 parfor + `trackOneChannel` 主开发线 |

版本演进摘要见根目录 `README.md` / `VERSION`。功能细节文档仍散落在 `docs/*.md`；**日常上手以本文为主线**，需要公式级或某次实验记录时再下钻单篇。

---

## 11. 关键 API 速查

```matlab
setupPaths
settings = initSettings('msToProcess', 60000, 'acqSatelliteList', [24 38 39 41]);
results  = run_B2a('msToProcess', 60000, 'acqSatelliteList', [24 38 39 41], ...
                   'doNavigation', true, 'doPlot', true);

% 或分步
% acq → preRun2 → tracking2_v6_fix2 → postNavigation

plotNavPost(results.navSolutions, results.settings);
exportNmea(results.navSolutions, results.settings, ...
    'trackResults', results.trackResults);
```

```text
python launch_b2a_ui.py
```

```matlab
% JSON 批处理（给 UI / 脚本用）
runFromJsonConfig('results/ui/xxx/ui_config.json')
```

---

## 12. 延伸阅读（按主题）

| 主题 | 文档 |
|------|------|
| 目录与契约 | `docs/architecture.md` |
| 捕获算法 | `docs/acquisition_design.md` |
| 跟踪与状态机 | `docs/tracking_design.md` |
| 定位桥接 | `docs/navigation_design.md` |
| 模块风险清单 | `docs/module_audit.md` |
| 载波辅助码 | `docs/plan_carrier_aided_code.md`、carrier_aid 冒烟文 |
| RAIM | `docs/raim_fde.md` |
| 多段 TOW / 加权 | `docs/ls_weight_multitow.md` |
| REACQ 与帧同步 | `docs/reacq_framesync_absample.md` |
| 并行 | `docs/par_fast_matlab.md` |
| NMEA | `docs/nmea_export.md` |
| 显示与百度 | `docs/nav_plot_baidumap_v013.md` |
| Web UI | `docs/web_ui_v016.md` |

---

**最后建议**：把本接收机想成三条传送带——捕获给“初值”，跟踪给“连续观测 + 比特”，定位给“几何与钟差”。你改的每一个开关，都应能说清它作用在这三条带的哪一段。说得清，排错就快；说不清，就先回到默认配置，用 `smoke_*` 把那一段单独跑通。
