# Before v0.1.6 历史代码归档

本目录保存 v0.1.6 之前的 Git 快照，供复现、差异审阅和故障追溯使用。快照来自仓库标签，目录内容不应作为当前运行入口：

| 快照 | 用途 | 当前替代品 |
|---|---|---|
| `v0.1.0` | 初始 B2a 接收机、旧的单流程入口 | `core/runFromJsonConfig.m`、`core/runFromSettings.m` |
| `v0.1.2` | 载波辅助码环实现及早期跟踪参数 | `tracking/` 当前载波辅助与 FLL/NH 状态机实现 |
| `v0.1.3` | 早期 PVT 绘图、地图展示 | `include/plotNavPost.m`、`launchBaiduMapTrack.m` |
| `v0.1.4` | RAIM/FDE 与 Baidu 地图初版 | `navigation/raimLeastSquarePos.m`、`include/plotNavPost.m` |
| `v0.1.5` | 多段 TOW、旧 NMEA GGA/GSV、旧平铺绘图目录 | `navigation/` 多段导航、`navigation/nmeaBuild*.m`、统一 `figures/*Result/` |

## 备份文件

`backups/` 中的三个 `.bak` 文件是 2026-08-13 调试时为 OOM 和捕获/跟踪回归保留的原始副本。它们只用于故障对比，不应加入 MATLAB path 或生产运行路径：

- `acquisition_robust_v2fft_20260813_1810.bak`
- `TrackResults2_20260813_oom.bak`
- `trackOneChannel_20260813_oom.bak`

当前代码统一通过 `setupPaths` 加载；历史快照没有单独的兼容保证。需要复现旧行为时，请在对应快照目录中阅读其 README 和 Git 版本信息，并将输出写到独立的实验目录。
