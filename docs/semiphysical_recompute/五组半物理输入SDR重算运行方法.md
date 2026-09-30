# 五组半物理输入 SDR 重算运行方法

日期：2026-09-29。适用于当前 `F:/matlab-GNSSsdr/BDS/B2a/core/runFromJsonConfig.m`。

本接口从原始 RF `.dat` 重跑捕获、跟踪和导航，产出新的 SDR 输入 MAT；后续再交给 `S4repair_basedOnSDR-v2` 修正。**本配置包初次整理时仅准备和核验配置。后续调试、修复、MATLAB 版本选择及已启动的完整重算见 [调试记录_20260929.md](调试记录_20260929.md)。**

## 1. 文件与入口

本目录 `F:/matlab-GNSSsdr/BDS/B2a/docs/semiphysical_recompute/` 包含：

```text
五组半物理输入SDR重算运行方法.md
run_five_semiphysical.m       轻量 MATLAB 启动接口
five_cases.json              五组索引、来源与输入路径
configs/
  01_dme_free.json
  02_1350_n50dBm.json
  03_1350_n60dBm.json
  04_2700_n50dBm.json
  05_2700_n60dBm.json
receiver_source_hashes.json   整理时的接收机源码哈希
verification.json            本次配置核验记录
```

**五份 `configs/*.json` 都是独立、可直接交给接收机的配置。** `five_cases.json` 是启动接口的索引，不可直接传给 `runFromJsonConfig`。

当前调用链：`runFromJsonConfig → tracking2_v6_fix2 → trackOneChannel → TrackResults2`。入口签名：

```matlab
report = runFromJsonConfig(jsonPath, ...
    'outDir', newOutputDirectory, ...
    'openBaiduBrowser', false, 'closeFigures', true);
```

`outDir` 的优先级为调用参数、JSON 中的 `outDir`、默认 `results/ui/<tag>`。JSON 经 `initSettings` 和入口允许的字段合并后运行；任意新增 JSON 字段不保证生效。入口也接受完整 settings 结构体，但把 `jsondecode` 得到的简略对象直接当 settings 传入，会跳过 JSON 参数合并，因此这里统一传 **JSON 文件路径**。

## 2. 五组配置保留的条件

RF 文件目录均为 `F:/Data/DME_BDSB2a/Spirent2026/new_atc5000/`。

| 编号 | 案例 | RF 文件 | 历史 SDR 目录尾名 | 带宽设置 MHz | PB 门限 dBm | `startOffset` ms |
|---:|---|---|---|---:|---:|---:|
| 1 | 无 DME | `720_0000_00_1176_25_37p5_17p5.dat` | `260805_064630_4ec665` | 18 | −76.5 | 68.802 |
| 2 | 1350 / −50 dBm | `720_1350_50_1176_25_37p5_17p5.dat` | `260811_175811_7e987b` | 17.5 | −93 | 1.1 |
| 3 | 1350 / −60 dBm | `720_1350_60_1176_25_37p5_17p5.dat` | `260811_161233_9313d2` | 17.5 | −93 | 1.1 |
| 4 | 2700 / −50 dBm | `720_2700_50_1176_25_37p5_17p5.dat` | `260811_135322_e2bef5` | 18 | −93 | 68.802 |
| 5 | 2700 / −60 dBm | `720_2700_60_1176_25_37p5_17p5.dat` | `260810_213741_76f7da` | 17.5 | −93 | 1.1 |

配置依据历史 `ui_results.mat:settings`，而非文件名中的增益等标签。共同设置：RF 25 MHz、零 IF、复 IQ `int16`、715000 ms、12 个通道、捕获 PRN 1–20、接收机增益 30 dB、标度常数 −94.72 dB、`intTime=0.001`、`longCoh_ms=1`、`CNoInterval=200`；FLL 启用、KF 关闭。保留多星捕获以产生导航时间锚，后续 S4 分析仍可只选 PRN 11。

**关键适配：**当前 `trackOneChannel` 优先采用 `PB_settings.Th_static_tracking`。本包显式令它等于历史保存的 `Th_static`：无 DME 数字幅度门限约 1288.1606，四个干扰组约 192.7392。这样不会继承当前 `initSettings` 的另一套跟踪默认门限。门限是幅度，不是平方功率。

默认开启导航、NMEA 和导航图，关闭逐星跟踪图、PB debug 图及百度地图；保留 `useParfor=true`、最多 4 个 worker。历史 `startOffset` 是接收机时间参数，不能作为闪烁注入的秒级对齐依据。接收机在线 `scint_fCutoff=0.1` 也不是后续 S4repair 的 0.01 Hz 趋势配置。

## 3. 推荐交互：MATLAB 中选择、预览、运行

```matlab
pkg = 'F:/matlab-GNSSsdr/BDS/B2a/docs/semiphysical_recompute';
addpath(pkg);

% 只准备五组配置，列出输入是否存在；不会读取 RF 或启动接收机。
preview = run_five_semiphysical();

% 可选：先完整重算无 DME 一组。
one = run_five_semiphysical(1, true);

% 或直接按无 DME、四个干扰组顺序重算全部。
batch = run_five_semiphysical(1:5, true);
```

两种执行方式择一使用；若先跑了第 1 组，可用 `run_five_semiphysical(2:5,true)` 继续其余四组，并保留各次调用的输出路径。

接口为 `run_five_semiphysical(caseIndices, execute, outputRoot)`：编号可选 `1`、`2:5` 或 `1:5`；`execute=false` 只准备，`true` 才运行。各 RF 文件顺序执行，每个文件内部按接收机配置多星并行；一组失败即停止，余下组维持 `prepared`。

每次调用默认新建：

`F:/matlab-GNSSsdr/BDS/B2a/results/semiphysical_recompute/<时间戳>/<案例名>/`

也可提供一个**尚不存在**的输出根目录作为第三参数。已存在目录会被拒绝，包括前一次预览目录；预览和正式运行默认各用新目录。JSON 模板不保留历史 `outDir/tag`，启动接口在每次准备时填入新的值。

如果并行池有问题，将需要运行的配置文件中 `useParfor` 改为 `false` 后重新调用即可。修改参数直接编辑对应 JSON；修改静态 PB 门限时，须同时更新 `Th_static_dBm`、`PB_settings.Th_static` 和 `PB_settings.Th_static_tracking`，换算为：

```matlab
amplitude = 10^((thresholdDbm - scaleK - gain + 10*log10(FsRF))/20);
```

不要把 1 ms 改成 MC 实验的 20 ms。改变 JSON 后已有预览快照不会自动更新，应重新准备。

## 4. 单独调用现有入口

不使用启动接口也可以运行一份 JSON：

```matlab
pkg = 'F:/matlab-GNSSsdr/BDS/B2a/docs/semiphysical_recompute';
cd('F:/matlab-GNSSsdr/BDS/B2a');
setupPaths;
jsonPath = fullfile(pkg, 'configs/02_1350_n50dBm.json');
outDir = fullfile('F:/matlab-GNSSsdr/BDS/B2a/results/semiphysical_recompute', ...
    char(datetime('now','Format','yyyyMMdd_HHmmss_SSS')), '1350_n50dBm');
report = runFromJsonConfig(jsonPath, 'outDir', outDir, ...
    'openBaiduBrowser', false, 'closeFigures', true);
disp(report);
```

入口失败常会返回 `report.ok=false`，而不是抛出异常；因此须检查 `report.ok` 和 `report.stage`。直接调用入口没有本包的已有目录保护，选择新的 `outDir`。

## 5. 现有 Web UI 的交互方式

现有页面支持表单编辑、**导出 JSON**、IF 探针和全流程运行，**没有导入 JSON 按钮**。手填主要参数适合探针诊断；要完整使用本包的嵌套门限配置，采用上述 MATLAB 方式，或向**已经启动**的 UI 后台提交完整对象：

```matlab
pkg = 'F:/matlab-GNSSsdr/BDS/B2a/docs/semiphysical_recompute';
base = strip(string(getenv('MY_API_BASE_URL')), 'right', '/');
assert(strlength(base)>0, '先设置 MY_API_BASE_URL 为现有 UI 服务的根地址');
cfg = jsondecode(fileread(fullfile(pkg, 'configs/02_1350_n50dBm.json')));
opts = weboptions('MediaType','application/json','Timeout',60);
key = getenv('MY_API_KEY');
if ~isempty(key), opts.HeaderFields = {'Authorization', ['Bearer ' key]}; end

% 此行会实际提交一个完整 SDR 任务。
job = webwrite(base + '/api/run', struct('config',cfg), opts);
state = webread(base + '/api/job/' + string(job.jobId), opts);
disp(state.status);
disp(state.outDir);
```

后台返回任务号后异步运行；可再次 `webread` 查看状态、`state.log` 和 `state.report`。前一组完成后再提交下一组。现有本地服务不要求 API Key；若使用有鉴权的服务包装层，Key 从环境变量读取。HTTP 失败查看 MATLAB 返回的错误信息，不显示 Key 或请求头。

UI 后台自行创建 `results/ui/<任务号>`，因此以返回的 `outDir` 为准；它不采用启动接口的分组目录。页面侧栏跟踪的是从该页面提交的任务，MATLAB/API 提交的任务用任务号查询。已有 UI 运行“全流程”的效果与入口相同，但页面默认设置不一定等于本包配置。

## 6. 输出检查与后续 S4 修正

成功条件：`report.ok=true`、`stage=done`，导航应有有效定位时间，且存在 PRN 11 跟踪分块。主要产物：

| 文件 | 用途 |
|---|---|
| `ui_config.json`、`report.json`、`matlab.log` | 实际请求配置、阶段与错误、运行日志 |
| `effective_settings.json`、`validation.json` | 实际生效参数及程序完成后的配置、定位和 PRN 11 完整性校验 |
| `ui_results.mat` | 当前版本的轻量包装：settings、导航、星历；不含完整跟踪数组 |
| `run_B2a_<tag>.mat` | 完整汇总结果，跟踪值以结构体保存 |
| `temp/Trk_Prn_11_*.mat` | 后续修正使用的原生 1000 Hz 跟踪分块；当前版本变量为 `chunk` |
| `temp/Trk_Prn_11_final.mat` | 全弧最终结构体 `finalTRes` |
| `pvt.nmea`、`figures/*Result/` | 导航时间/定位与诊断图 |

启动接口还写出根目录的 `recompute_summary.csv/.mat`，记录五组输出路径、成功标志、捕获数、定位数和耗时；正式运行时保存 `receiver_runtime.json` 中的 MATLAB 版本、项目版本标签及实际入口路径。`prepared` 表示未执行，不能当作成功结果。

调试版另区分 `running`、`failed`、`validation_failed`；只有执行和结果校验均通过才标为 `done`。可加名称参数 `'ContinueOnFailure',true`，逐组记录失败后继续尝试其他输入。长时间 MCP 调用可使用新增的 `start_five_semiphysical` 异步入口，详情见调试记录；不要重复提交已经启动的队列。

后续将新组目录赋给 `s4repair` 的 `cfg.resultDir`；先处理无 DME 并取得其结果 CSV，再设其余组的 `cfg.truthResultsCsv`。新处理设置仍为 `processingMode="mc_aligned_iir"`、`useJointThresholdFit=true`、`coherentIntegrationSec=0.001`，并正确设置各组 `knownNoInterference`。原 `main_testCurrentData.m` 仍固定指向历史五目录，不会自动发现这里的新结果。

重算接收机本身不会证明五个 RF 文件的闪烁注入时间对应关系；参考配对仍须依据已核实的时间记录。

**核验范围：**五份 JSON 解析、原始输入存在性、1 ms 参数、门限换算与新目录准备流程已通过；未运行完整捕获/跟踪/导航。原接收机业务代码和历史结果未修改。原 JSON 及当前入口/配置源码备份位于 `F:/matlab_project/dme_L5_Scintillation-v2/backups/before_sdr_recompute_package_20260929/`。
