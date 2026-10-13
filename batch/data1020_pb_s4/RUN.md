# DATA1020 PB 02、04、05 应用批处理

原计算源码保持原样。外部入口调用 `s4repair.s4.processAlignedTrack`，三组按 02、04、05 的顺序处理。结果写到 `F:/matlab-GNSSsdr/BDS/S4repair_basedOnSDR-v2/results/data1020_pb_02_04_05_s4`。

## 入口

- `data1020_config.m`：三组配置、26个实验—卫星组合、频偏及UTC锚点。
- `data1020_preflight.m`：全部输入、分块与final一致性、UTC、SSC资源和四个分钟窗的检查。
- `data1020_main.m`：主计算、逐星保存、绘图、导航关联和汇总。
- `data1020_compute.m`：调用原计算核心并应用硬件有效性配置。
- `data1020_plot.m`：UTC三曲线、差值、输入诊断和逐星汇总图。
- `launch_data1020.ps1 -Stage main`：R2024b后台启动。R2026a的MCP连接超时，命令行启动退出码为−1073741819，因此本次使用R2024b。

## 参数

| 实验 | PRN | DME频率 | 相对采样中心频偏 |
| --- | --- | --- | --- |
| 02 | 24、27、28、32、33、38、39、41 | 1170 MHz | −6.45 MHz |
| 04 | 25、27、28、30、32、33、38、39、41 | 1170 MHz | −5.40 MHz |
| 05 | 24、27、28、30、32、33、38、39、41 | 1170 MHz | −5.40 MHz |

读取运行时20 MHz采样率、1 ms Prompt、各组静态PB门限和功率标度。分钟窗口使用UTC自然分钟。常规修正使用Pilot C/N0。仰角不参与选星。

原 `receiverCalibration` 按原条件计算；外部设置 `forceHardwareValid=true`。计算通过已有 `allowUnverifiedFrontendModel=true` 得到完整所提值，汇总时把硬件有效性置真，`proposedValid` 使用模型计算门控，其余质量门控保留。原硬件判定保存在 `hardwareRuleResult`，执行配置保存在 `hardwareValidityForced`。这项值来自本次用户配置。

05/PRN24包含非LONG状态；05/PRN28包含重捕。使用原代码的状态选择和重捕分弧，每个入选星保留全部分钟窗、有效性及状态字段。

## 输出

说明、数值表格及日志为Markdown；数组和诊断为MAT；图件为PNG、PDF、EPS、SVG、FIG；图片索引为HTML。

- `main_console.md`：主计算实时日志。
- `experiments/02-HUR_1-PB`、`04-103330-PB`、`05-103801-PB`：逐实验结果。
- `experiments/*/tracks/prnXX.mat`、`prnXX.md`：逐星结果。
- `experiments/*/publication_figures/gps_solutions`：三方案曲线、差值和诊断图。
- `experiments/*/receiver_context`：原卫星底图、导航图及UTC轨迹点表。
- `tables/all_windows.md`、`tables/summary.md`、`tables/navigation_window_links.md`：统一汇总。
- `index.html`：按实验对应地图、导航、S4图表。
- `completion.md`：全部计算完成记录。

窗口图使用共同有效分钟，全部计算值另存表格。没有独立真值，统计呈现三种S4的均值、差值、有效窗数和截零数量。

主任务启动后本轮交付结束，用户通过 `main_console.md` 查看运行进度。
