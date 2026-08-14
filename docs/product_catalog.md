# BDS B2a SDR 产品目录

本文档描述 v0.1.6 之后的当前产品边界、正式入口和输出契约。历史实现位于 `legacy/BeforeV0_1_6`，不加入当前 MATLAB path。

## 1. 产品能力

| 能力 | 当前实现 | 主要输出 |
|---|---|---|
| IF 配置与数据探测 | `config/initSettings.m`、`core/runProbeIf.m` | IF 时域/频域探测图 |
| B2a 捕获 | `acquisition/acquisition_robust_v2fft.m`、`core/runAcquisition.m` | `acqResults`、`figures/AcqResult` |
| 多通道跟踪 | `tracking/tracking2_v6_fix2.m`、`tracking/trackOneChannel.m` | `temp/Trk_Prn_*_final.mat`、`figures/trkResult` |
| 导航电文与 PVT | `navigation/BCNAV2decoding.m`、`navigation/postNavigation.m` | `navSolutions`、`eph` |
| RAIM/FDE 与加权定位 | `navigation/raimLeastSquarePos.m`、`leastSquarePos.m` | 有效 PVT、卫星使用统计 |
| NMEA 0183 | `navigation/exportNmea.m`、`nmeaBuildGGA/GSA/GSV/ZDA.m` | `pvt.nmea` |
| 离线回放 | `core/runNavigationFromTracking.m`、`tests/replay*Channels.m` | 更新后的 NMEA、PVT MAT、离线图片 |
| 产品补救 | `core/repairUiResultDirectory.m` | 从 `run_B2a_*.mat`/`navigation_replay.mat` 补齐统一 UI 产品 |
| Web UI | `launch_b2a_ui.py`、`python/b2a_ui`、`web/ui` | `results/ui/<jobId>` |
| 目录批处理 | `batch/batchDirForOneSettings.m` | `results/batch/<batch>/<item>` |

## 2. 正式入口

| 入口 | 使用场景 | 输出根目录 |
|---|---|---|
| `python launch_b2a_ui.py` | 推荐的交互式全流程 | `results/ui/<jobId>` |
| `init_B2a.m` | 使用原始 `initSettings()` 的 MATLAB 全流程 | `results/ui/<yyMMdd_HHmmss>` |
| `runFromJsonConfig(jsonPath)` | 自动化、Web UI、可复现配置 | JSON 的 `outDir`，默认 `results/ui/<tag>` |
| `runFromSettings(settings)` | MATLAB 参数化全流程 | 参数 `outDir`，默认 `results/ui/<tag>` |
| `batchDirForOneSettings(...)` | 一个配置批量处理目录 | `results/batch/<tag>_<input>` |
| `runNavigationFromTracking(runDir)` | 不重复捕获/跟踪，直接重做定位 | 原运行目录 |

`core/run_B2a.m` 保留为兼容入口，但新代码应优先使用 `runFromSettings`，以获得完整的配置快照、报告和统一目录。

## 3. 单次运行输出契约

```text
results/ui/<tag>/
  ui_config.json
  report.json
  matlab.log                  # Web UI/批处理时存在
  ui_results.mat
  run_B2a_<tag>.mat
  pvt.nmea
  navigation_replay.mat       # 离线重定位后存在
  navigation_satellite_usage.csv
  temp/
    Trk_Prn_<PRN>_<chunk>.mat
    Trk_Prn_<PRN>_final.mat
  figures/
    AcqResult/
    trkResult/
    navResult/
```

`ui_results.mat` 是轻量定位包装，包含设置、捕获摘要和导航结果；完整跟踪数组保留在
`run_B2a_<tag>.mat` 与 `temp/`，避免下游定位加载时触发大 MAT 序列化或内存峰值。
历史目录可用以下命令补齐产品：

```matlab
setupPaths;
repairUiResultDirectory('results/ui/260814_032637', 'Force', true);
```

批处理根目录额外包含 `source_config.json`、`batch_report.json` 和 `batch_report.mat`；每个编号子任务遵守同一单次运行契约。

## 4. 文档索引

- `docs/quickguide.m`：运行、测试、直接定位和图片重放命令。
- `docs/user_manual_zh.md`：完整中文用户手册。
- `docs/architecture.md`：模块与数据流。
- `docs/acquisition_design.md`、`tracking_design.md`、`navigation_design.md`：算法设计。
- `docs/nmea_export.md`、`raim_fde.md`：定位输出和完整性监测。
- `legacy/BeforeV0_1_6/README.md`：历史版本替代关系。
