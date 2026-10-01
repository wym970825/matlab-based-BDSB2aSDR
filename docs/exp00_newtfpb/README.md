# Exp00：五组半物理数据 800 kHz / 3 μs 全量重算

本次按用户要求运行五组完整中频数据。新结果位于 `results/Exp00-newTFPB/<案例名>/`；此前已通过验收的五组 PB 全量结果已**移动**至 `results/Exp01-oldPB/<案例名>/`，并非复制。完整执行和验收状态以新目录的 `experiment_status.json` 和各组校验文件为准，不能以配置文件或文件夹存在判定完成。

## 配置依据

逐组读取旧全量结果的 `effective_settings.json`，保持保存的全部接收机参数，替换前端及输出路径。没有采用此前参数扫描中“PRN 11 单星、关闭导航”的简化配置。

共同参数为：715000 ms、25 MHz、零 IF、int16 交织 IQ、字节偏移 0、PRN 1–20 捕获、最多 12 通道、原生 1 ms 积分、LONG 1 ms、4 个进程 worker；导航、NMEA 和导航图仍保持旧实验选择。

| 案例目录 | 原始中频文件 | 幅度门限 | IFBandwidth | startOffset |
|---|---|---:|---:|---:|
| `dme_free` | `720_0000_00_1176_25_37p5_17p5.dat` | 1288.1605785 | 18 MHz | 68.802 ms |
| `1350_n50dBm` | `720_1350_50_1176_25_37p5_17p5.dat` | 192.7391788 | 17.5 MHz | 1.1 ms |
| `1350_n60dBm` | `720_1350_60_1176_25_37p5_17p5.dat` | 192.7391788 | 17.5 MHz | 1.1 ms |
| `2700_n50dBm` | `720_2700_50_1176_25_37p5_17p5.dat` | 192.7391788 | 18 MHz | 68.802 ms |
| `2700_n60dBm` | `720_2700_60_1176_25_37p5_17p5.dat` | 192.7391788 | 17.5 MHz | 1.1 ms |

TF v1 采用复数 FIR，中心 −450 kHz、深阻带总宽 800 kHz、每侧频率过渡 150 kHz、641 抽头、Kaiser β=5.65326、脉冲尾部裕量 2 μs。扩展平台之外每个软过渡跨度配置为 3 μs；25 MHz 离散取整后为 3.04 μs。幅度门限继承各组旧 `PB_settings.Th_static_tracking`，无 DME 组也按用户要求启用同一 TF 模式。

`Frontend.mode='tf_v1'` 与传统 PB 互斥，因此有效 `EnablePB=false` 是必要的前端选择变化，不是遗漏消隐。其余旧字段由脚本逐项检查，JSON null 与 NaN、向量行列方向按数值含义比较。输出目录、标签和执行元数据另行记录。当前源码与旧 PB 实验的历史版本不同，本次保证参数逐组匹配，不将历史结果差异直接归因于单一算法因素。

## 旧结果移动记录

`results/Exp01-oldPB/relocation_manifest.json` 记录每组原路径、目标路径、逐文件相对路径及字节数、关键 JSON 文件 SHA-256。移动前确认所有源与目标均在项目指定结果目录内，目标不重名；移动后核对文件数、总大小和关键元数据哈希。每组 118 个文件，共约 14.3 GiB。

旧 MAT、配置和校验文件保持原始内容，因此其中的历史绝对输出路径仍指向原位置；定位实际文件时使用迁移映射。未验收的历史失败尝试、父目录调试资料和其他 TF 扫描结果不在此次移动范围内。

## 执行与验收

运行器为 [run_exp00_case.m](run_exp00_case.m)，后台编排为 [supervise_exp00.py](supervise_exp00.py)。每个任务启动独立 R2024b，隔离偏好目录及并行作业目录，不占用用户的共享 MATLAB 会话。使用旧五组全量实验已验证的 4-worker 运行方式。

顺序为：五组配置预检 → 第 4 组 5 秒多星并行短测 → 五组 715 秒完整运行。脚本拒绝覆盖已有运行报告；失败会停止队列并保留现场。源码哈希在各任务开始前核对，防止长任务期间悄然换用另一版程序。

主要文件：

- 根目录 `experiment_plan.json`、`source_manifest.json`：实验来源、输入、请求配置和源码指纹。
- 根目录 `experiment_status.json`、`supervisor.log`：任务状态及异常；`_runtime/` 保存各独立进程的日志、完成记录和并行作业现场。
- 各案例 `planned_config.json`、`preflight.json`、`run_config.json`、`effective_settings.json`：计划、派生前端参数、实际请求和生效配置。
- 各案例 `report.json`、`validation.json`、`all_tracks_validation.json`：流程、导航/PRN 11/分块/NMEA 校验，以及所有已捕获卫星的跟踪长度、前端有效性、时间轴、重捕获、C/N0 和 S4 有限样本数。
- 各案例 `run_B2a_*.mat`、`ui_results.mat`、`temp/`、`pvt.nmea`、`figures/`：完整结果、轻量导航结果、跟踪分块、NMEA 和图。

只有完整流程成功、旧配置比较无非预期差异、PRN 11 全弧及分块通过校验，并且所有保存通道的跟踪/前端完整性检查通过，才标记该组完成。导航解数量和监测指标由实际运行产生，不预设必须等于旧 PB 结果。

## 已完成的准备与短测

2026-10-01 23:26（北京时间）：五组预检全部通过，结果见 [预检汇总](evidence/preflight_summary.json)。第 4 组 5 秒多星并行短测也已通过，8 个通道各完成 5000 历元，全部通过前端有效样本、边界和正常跟踪段时间轴检查，见 [短测验收](evidence/smoke_validation.json)。此短测关闭导航，仅验证并行执行及跟踪完整性；全量请求仍保留各组原来的导航和输出开关。

五组 715 秒全量队列于短测结束后自动开始。全量是否完成，应读取 `results/Exp00-newTFPB/experiment_status.json` 中各 `phase="full"` 任务的状态及完成记录。本节记录启动节点，不代表五组全量已完成。

归档证据还包括 [实验计划](evidence/experiment_plan.json)、[源码指纹](evidence/source_manifest.json) 和 [旧结果迁移汇总](evidence/relocation_summary.json)。本轮未推送 GitHub，未修改接收机业务源码。
