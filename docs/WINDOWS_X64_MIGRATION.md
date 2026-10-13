# Windows x64 迁移、MEX 重编译与完整运行说明

更新日期：2026-10-13。适用对象：本项目当前 `experiment/exp00-tf800-3us` 代码线，以及由它创建的后续版本。

本文按实际迁移顺序执行：**取得完整代码 → 搬运数据 → 安装环境 → 编译 MEX → 配置路径 → 无 GUI 短测 → 导航/地图/S4 验收 → 长批处理**。部署到另一台 Windows 电脑与 Windows x64 服务器使用同一流程。

## 1. 本次提交与版本选择

本次将 `batch/data1020_tf_h0/`、`batch/data1020_pb_s4/`、`batch/package_data1020_pb_s4_plan.py` 及迁移文档纳入版本管理，接收机算法与 `.gitignore` 保持不变。提交前基线为 `1e440c3233b1d560f357f3b9610e24a1672ad917`；本次提交号用以下命令获取：

```powershell
git branch --show-current
git log -1 --format="%H %s"
git status --short
```

截至 2026-10-13 的远端核对，GitHub 只有 `master`、`mexBaseFast`、`par-fast-matlab`，当前实验分支还没有发布。**本地 commit 和上传 GitHub 是两个步骤**。将本次提交所在分支发布后，目标机才能通过以下命令取得它：

```powershell
git clone --branch experiment/exp00-tf800-3us https://github.com/wym970825/matlab-based-BDSB2aSDR.git E:\GNSS\B2a
Set-Location -LiteralPath E:\GNSS\B2a
git log -1 --format="%H %s"
```

如果分支还未发布，可以直接复制当前项目；或在源机制作包含本地分支的 bundle：

```powershell
git bundle create E:\transfer\B2a-current.bundle --all
git bundle verify E:\transfer\B2a-current.bundle
```

其中 `E:\transfer` 先建好。目标机从 bundle 获取代码：

```powershell
git clone --branch experiment/exp00-tf800-3us E:\transfer\B2a-current.bundle E:\GNSS\B2a
```

bundle 包含已提交的 Git 对象，不包含被忽略的数据、结果和 MEX 二进制。不要直接 clone 远端旧 master 后，仅靠复制两个 MEX 来补功能；当前 TF 前端和配置入口修订也属于 MATLAB 源码。

## 2. 文件迁移清单与容量

建议目标机统一采用以下布局，盘符可以改变：

```text
E:\GNSS\B2a\                         接收机代码与批处理
E:\GNSS\S4repair_basedOnSDR-v2\        独立 S4 修正项目
E:\GNSSData\DATA1020\                 原始 IF
E:\GNSSResults\                      新实验结果
```

保留原 F 盘目录布局时，现有外部实验脚本需要改的路径最少。改为上述布局时，按第 5 节调整配置，接收机算法无需改变。

| 内容 | 是否通过本次 Git 提交携带 | 目标机处理 |
| --- | --- | --- |
| 接收机 `.m`、MEX `.c`、Python、PowerShell、网页模板、文档 | 是，按现有规则纳入 | clone/复制当前分支。 |
| `results/` 历史结果、`*.bin`、`*.dat`、通常位置的 `*.mat` | 否 | 按实验另复制；`.gitignore` 对 `docs/**` 有现有例外，不改动。 |
| `mex/*.mexw64` | 否 | 新机器重新编译，或先复制旧文件进行兼容性验证。 |
| `config/BaidumapKey.txt` | 否 | 百度地图需要时单独设置。 |
| Python 虚拟环境、`__pycache__`、MATLAB 临时文件 | 否 | 新机器按需要创建。 |
| 独立 S4 项目及 `resources/` | 不属于本 Git 仓库 | 另复制完整项目/数值资源。 |

需要复现近期实验时，至少带走：

- `results/data1020/20261009_pb_tf_comparison/`：六组 PB/TF 配置、manifest、跟踪和导航产品、地图缓存。
- `results/data1020/20261010_tf_h0_20s/`：H0 门限和频谱参数、20 秒短测与分析结果。只保留图表不能重新做逐星分析。
- 独立 S4 项目的 `+s4repair/`、`resources/`、配置及需保留的 `results/`。
- 对应原始 IF。只回放完整跟踪做导航/S4 时可有步骤不读 IF；重捕获、重跟踪、频谱估计都要原始 IF。

当前六份 IF 合计 104 GB：01–05 各 16 GB，06 为 24 GB。两个 B2a 对比结果目录合计约 12.829 GB。整个 B2a 目录约 120.906 GB，整个 S4 项目约 1.304 GB。连同六份 IF 整体迁移约 226.2 GB，另留 MATLAB 安装和新结果空间；以上为文件逻辑大小，GB=10⁹ 字节。

目录复制示例：

```powershell
robocopy F:\matlab-GNSSsdr\BDS\B2a E:\GNSS\B2a /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ
```

这条命令复制现有目录，包括 `.git` 和历史结果；不会应用 `.gitignore`。Git 提交范围与整个文件夹复制范围不同。复制原始 IF 后，用 `Get-Item` 比较长度，并用 `Get-FileHash -Algorithm SHA256 -LiteralPath '完整文件路径'` 比较源、目标校验值。完整 IF 校验会读取整个大文件，宜在传输完成后统一做一次。

## 3. 安装 Windows x64 环境

### 3.1 MATLAB 与工具箱

安装目标版本支持的 Windows x64 操作系统、完整 MATLAB 和运行账号可用的许可。优先 R2026a；近期 H0 短测和 PB-S4 外部启动器实际使用 R2024b，复现实验可以保留这一版本。MATLAB 安装目录不能靠从旧电脑复制程序文件夹代替安装。

| 软件 | 作用 |
| --- | --- |
| MATLAB | 执行接收机 `.m`、MAT 数据读写及图件导出。 |
| Signal Processing Toolbox | Welch PSD、TF FIR、闪烁去趋势等。 |
| Communications Toolbox | B-CNAV2 的 `comm.CRCDetector`，完整导航需要。 |
| Parallel Computing Toolbox | 并行捕获、并行跟踪；串行时不需要。 |
| Optimization Toolbox | 独立 S4 项目联合拟合中的 `lsqnonlin/optimoptions`。 |
| Statistics and Machine Learning Toolbox | 同一 S4 联合拟合中的 `ncx2cdf`。 |

普通 `geoaxes/geoplot/geobasemap` 和当前离线瓦片拼图不统一依赖 Mapping Toolbox。现有配色转换已包含在 `batch/data1020_purple_orange.m`，不额外依赖 Image Processing Toolbox。

当前入口启动完整 MATLAB，仓库没有 MATLAB Compiler 生成的独立程序；只装 MATLAB Runtime 不能直接执行这套源码。[Runtime 用途](https://www.mathworks.com/help/compiler/matlab-runtime.html)

### 3.2 Python、Git 与资源

安装 Git for Windows、64 位 Python 3.9+；可固定 Python 3.11 或 3.12。Web UI 本身只依赖标准库，不需要 `pip install matlabengine`、Node.js、npm。`python` 命令应在实际运行账号的 PATH 中可用：

```powershell
git --version
python --version
Get-Command python
```

长时间实验优先本地 SSD/NVMe。20 MHz、int16 IQ 每秒读取 80 MB 原始数据。先用一个 MATLAB 进程、串行，再测试 2–6 workers；当前代码硬上限为 6。32 GB 可作为内存容量规划起点，64 GB 更适合多星并行和长结果回放；实际并发量用短测峰值确认。GPU 不会自动加速现有 CPU/MEX 路径。

Windows 计划任务使用的账号也必须拥有数据读取、结果目录写入权限及 MATLAB 许可；它的 PATH/环境变量不一定与当前登录桌面一致。

## 4. MEX：需要编译什么、怎样编译与验收

### 4.1 两个本地二进制

| 源文件 | Windows x64 编译产物 | 调用位置 |
| --- | --- | --- |
| `mex/correlateB2aMs_mex.c` | `mex/correlateB2aMs_mex.mexw64` | `tracking/correlateB2aMs.m`，数据/导频 E/P/L 相关。 |
| `mex/pulseBlank_core_mex.c` | `mex/pulseBlank_core_mex.mexw64` | `channelCtrl/pulseBlanker.m`，复数 PB 消隐与功率统计。 |

构建入口为 [mex/build_mex.m](../mex/build_mex.m)。TFBlankerV1 本身是 MATLAB 实现，**没有第三个必须编译的 TF MEX**；TF 跟踪仍会使用相关器 MEX。

`.mexw64` 是 Windows 64 位 MEX，不是跨平台文件。迁移到新机器、新 MATLAB 版本、改变编译器或改动 C 源码时，优先在目标机重新编译，并把 MATLAB/编译器版本记在日志里。[MEX 平台兼容性](https://www.mathworks.com/help/matlab/matlab_external/platform-compatibility.html)

没有这两个 MEX 时，当前封装有纯 MATLAB 计算路径；若旧 MEX 文件存在但无法加载，封装不会自动把任意加载错误转成纯 MATLAB 重试。正式长实验应完成本机编译与验收。

### 4.2 安装编译器

本项目 Windows 构建已验证 **Microsoft Visual C++ 2022**。安装 Visual Studio 2022 或 Build Tools 2022，选择 C++ 桌面开发对应工作负载，包含 **MSVC v143 x64/x86 构建工具与 Windows SDK**。不需要为 MEX 安装 MATLAB Compiler 产品。

采用 MSVC 2022 路线，因为 `build_mex.m` 的 Windows 分支明确使用 `/O2` 的 MSVC `COMPFLAGS`。不能只安装 MinGW 后认定该脚本无需调整就等价；若选择其他工具链，应另外适配构建参数并验证数值。[MathWorks 编译器选择](https://www.mathworks.com/support/requirements/supported-compilers.html)、[mex 文档](https://www.mathworks.com/help/matlab/ref/mex.html)

编译器安装完成后重新启动 MATLAB 进程。在用于运行接收机的同一 MATLAB 版本中执行：

```matlab
disp(version)
disp(computer('arch'))           % 应为 win64
disp(mexext)                     % 应为 mexw64
mex.getCompilerConfigurations('C','Installed')
mex -setup C
mex.getCompilerConfigurations('C','Selected')
```

`mex -setup C` 在多个候选时选择 Microsoft Visual C++ 2022；只有一个可用编译器时通常直接配置。R2024b 与 R2026a 各自保存编译器设置，应分别检查。C 源码的接口为 interleaved complex，构建脚本已对两项指定 `-R2018a`；不要省略该 API 选项手工试编。

### 4.3 正式重编译

关闭正在使用目标 MEX 的接收机任务和并行 worker；启动一个新的 MATLAB 命令行进程。不要在仍运行的跟踪任务旁覆盖其 MEX 文件。

```matlab
cd('E:/GNSS/B2a')
setupPaths
mkdir('results/deployment')
diary('results/deployment/mex_build.md')
disp(version)
disp(mex.getCompilerConfigurations('C','Selected'))
build_mex
rehash
which correlateB2aMs_mex -all
which pulseBlank_core_mex -all
assert(exist('correlateB2aMs_mex','file') == 3)
assert(exist('pulseBlank_core_mex','file') == 3)
diary off
```

产物应落在本项目 `mex/`。脚本会切换构建目录并恢复工作目录，Windows 相关器使用 `-O -R2018a` 与 `/O2`。x64 MSVC 已提供 SSE2，当前脚本不再传过时的 `/arch:SSE2`。

两项都构建完成后，**再开一个新的 MATLAB 进程验收**。`correlateB2aMs` 和 `pulseBlanker.mitigate` 都用 persistent 变量缓存是否存在 MEX；新进程同时清除这类缓存与旧二进制加载状态。`rehash` 只刷新查找，不等价于重置所有持久变量和并行 worker。

若同一目录要交替运行 R2024b/R2026a，建议各用一份 checkout 并分别编译到各自 `mex/`。一个共享 `mex/` 同时只有一套同名文件，不能把其构建来源当成两个版本都已验证。

### 4.4 快速加载和 PB 数值验证

在新 MATLAB 进程中执行，既确认文件可加载，也核对实际输出：

```matlab
cd('E:/GNSS/B2a'); setupPaths
which correlateB2aMs_mex -all
which pulseBlank_core_mex -all
x = complex([1 3 -2 0.5],[0 4 0 -0.5]);
threshold = 2.5;
[y,preDb,postDb,eta] = pulseBlank_core_mex(x,threshold);
expected = x;
expected(abs(expected)>threshold) = 0;
assert(isequal(y,expected));
assert(abs(eta-mean(abs(x)>threshold)) < 1e-12);
assert(abs(preDb-10*log10(mean(abs(x).^2)+1e-30)) < 1e-12);
assert(abs(postDb-10*log10(mean(abs(expected).^2)+1e-30)) < 1e-12);
```

相关器还应经过真实 IF 短测。更完整的确定性数值检查已包含在 [run_r2026a_compatibility.m](../tests/run_r2026a_compatibility.m)：对重新编译的相关器与 MATLAB 参考实现做归一化误差、码相位和载波相位比较。该入口还会重编译隔离副本、检查绘图和 IF 探针，属于完整兼容验收，不只是 MEX 加载探针：

```matlab
report = run_r2026a_compatibility( ...
    fullfile(pwd,'results','deployment','compat_r2026a_01'));
assert(report.ok);
```

输出目录必须是新目录；`prebuiltMex` 检查要求项目 `mex/` 已有两个编译产物，因此 fresh clone 应先 `build_mex`。兼容测试使用隐藏图窗，但会执行图形子系统；只做轻量数值/跟踪验收时，不必同时执行整套图形测试。相关器使用 LUT/SSE2 近似，数值验收采用测试内定义的容差，不要求与三角函数 MATLAB 路径逐位相同。

### 4.5 常见编译和加载问题

| 现象 | 处理 |
| --- | --- |
| `No supported compiler` | 检查 C++ 工作负载、MSVC、SDK 是否实际安装；重开目标 MATLAB，再执行 `mex -setup C`。 |
| 编译链接时无法写 `.mexw64` / 文件被占用 | 结束加载该 MEX 的 MATLAB/worker，使用独立构建进程；不在运行任务中覆盖。 |
| `Invalid MEX-file`、找不到指定模块 | 核对 `which -all`、`win64/mexw64`、目标 MATLAB 版本；检查 MSVC x64 运行库及依赖 DLL，在目标机重编译。 |
| 文件存在却不被调用 | 检查 path 是否指向其他 checkout，重启进程清除 persistent 缓存。 |
| 串行正常、worker 失败 | 重建并行池，检查 worker 使用相同源码/MEX 路径与运行环境。 |
| 换版本后输出或性能变化 | 固定相同 IF、配置、PRN、时间窗复测，记录 MATLAB/编译器版本；不能仅比较生成文件大小。 |

Windows 的“找不到指定模块”也可能是 MEX 所依赖的 DLL 缺失，而不是 `.mexw64` 本身不存在。使用对应 Microsoft x64 运行库和正常 MATLAB 环境，不从不明来源复制同名 DLL。[MathWorks MEX 加载错误说明](https://www.mathworks.com/help/matlab/matlab_external/invalid-mex-file-error.html)

## 5. 修改路径与实验参数

进入项目后仅调用 `setupPaths`。它按自己的位置添加正式模块；不要 `addpath(genpath(...))` 把 `legacy/`、历史快照和结果程序全部混入当前 path。

| 位置 | 需要设置的内容 |
| --- | --- |
| JSON 或 settings | `filePath/fileName/outDir`；从文件头开始时明确 `skipNumberOfBytes=0`。 |
| `config/ui_defaults.json` | 更新旧机器 IF 路径及目标机默认值。 |
| 实验 manifest | `sourceFile/pbDir/tfDir/outputRoot/analysisDir` 等绝对路径。 |
| `batch/data1020_tf_h0/` | 各 `.m` 的接收机根目录/结果目录、`launch.ps1` 中 MATLAB 路径、报告程序根目录。 |
| `batch/data1020_pb_s4/` | B2a 和 S4 根目录、源结果目录、输出目录、MATLAB 路径。 |
| `batch/package_data1020_pb_s4_plan.py` | `ROOT/S4/DESTINATIONS`，尤其 H 盘备份与另一个论文项目路径。 |
| S4 cfg | `receiverRoot/resultDir/outputDir` 与资源位置。 |
| 地图 | `baiduMapKeyFile`，卫星瓦片缓存与带新绝对路径的瓦片 manifest。 |

不要直接在已归档的原结果上全盘替换字符串；在外部 cfg/manifest 副本里重映射，再写到新的结果目录。`ui_results.mat` 含轻量设置与导航信息；完整 Prompt/跟踪数组保存在 `temp/Trk_Prn_*_final.mat` 或完整运行 MAT，做 S4 时要保留这些数据。

本批数据的关键频率如下，文件名写 `ZeroIF` 不代表 B2a 信号的数字 IF 必定为零：

| 实验 | `samplingFreq` | 采样中心 | 接收机 `IF` | H0 谱陷波中心 `centerHz` 约值 |
| --- | ---: | ---: | ---: | ---: |
| 02 / HUR_1 | 20e6 | 1176.45 MHz | 0 | −6450195.3125 |
| 04 / 103330 | 20e6 | 1175.40 MHz | +1050000 | −5400390.625 |
| 05 / 103801 | 20e6 | 1175.40 MHz | +1050000 | −5390625 |

`Frontend.TF.centerHz` 是原始 IQ 数字频率，不能填射频 1170 MHz，也不能再加 `settings.IF`。采样类型为交织 int16、`fileType=2`，每个复样点 4 字节。明确指定静态 ADC 门限才能复现旧 PB；改变采样率/硬件后不能直接借用其他数据的门限。

## 6. 无 GUI 运行和 Web 控制

### 6.1 启动环境检查

在 PowerShell 中明确选择 MATLAB，不依赖 PATH 自动挑版本：

```powershell
$b2aRoot = 'E:\GNSS\B2a'
$b2aMatlab = 'C:\Program Files\MATLAB\R2026a\bin\matlab.exe'
Set-Location -LiteralPath $b2aRoot
& $b2aMatlab -wait -batch "disp(version); disp(computer('arch')); disp(mexext)"
```

如果 R2026a 在执行项目语句前退出，先看启动日志。项目 [R2026a 兼容记录](r2026a_compatibility.md) 说明了本机的 preferences/启动问题；Web runner 有隔离 preferences 和 `r_wait` 方式。用于复现上一轮结果时可明确选择 R2024b 的可执行文件。不要同时启动多个实例重复试错。

### 6.2 保存外部运行程序

下面内容保存为项目根目录下自用的 `server_run.m`，也可以存到独立脚本目录后用 `addpath` 调用。示例复用迁移后的 **02 原 PB 完整配置**，只修改目标机路径、时长、串并行与图件开关：

```matlab
cd('E:/GNSS/B2a'); setupPaths
set(groot,'defaultFigureVisible','off');
cfg = jsondecode(fileread( ...
  'results/data1020/20261009_pb_tf_comparison/02-怀柔-HUR_1/ui_config.json'));
cfg.filePath = 'E:/GNSSData/DATA1020';
cfg.fileName = 'data_1020_HUR_1.bin';
cfg.skipNumberOfBytes = 0;
cfg.msToProcess = 5000;
cfg.acqSatelliteList = [27 38 41];
cfg.numberOfChannels = 3;
cfg.useParfor = false;
cfg.useParallelAcquisition = false;
cfg.parMaxWorkers = 1;
cfg.PB_settings.debugplot = false;
cfg.doNavigation = false;
cfg.doNmea = false;
cfg.doPlot = true;
cfg.plotTracking = true;
cfg.plotNavPost = true;
cfg.doBaiduMap = false;
cfg.tag = 'migration_pb_5s';
report = runFromJsonConfig(cfg,'outDir','E:/GNSSResults/migration_pb_5s', ...
    'openBaiduBrowser',false,'closeFigures',true);
assert(report.ok);
```

没有带旧结果包时，先按 [通用指南的短测配置示例](迁移与全功能运行指南_20261013.md) 构造 cfg；Git 本身不携带上面读取的历史 `ui_config.json`。正式复现实验优先使用原完整配置。

无 GUI 后台启动：

```powershell
$b2aRoot = 'E:\GNSS\B2a'
$b2aMatlab = 'C:\Program Files\MATLAB\R2026a\bin\matlab.exe'
New-Item -ItemType Directory -Path (Join-Path $b2aRoot 'results\deployment') -Force | Out-Null
$b2aArgs = '-wait -singleCompThread -logfile "E:\GNSS\B2a\results\deployment\receiver_console.md" -batch "server_run"'
$b2aProcess = Start-Process -FilePath $b2aMatlab -ArgumentList $b2aArgs -WorkingDirectory $b2aRoot -WindowStyle Hidden -PassThru
$b2aProcess.Id
```

`-batch` 会在脚本结束后退出；`-wait` 供 Windows 启动/监督程序等待执行结果；`-singleCompThread` 是本轮串行验收的计算线程限制。日志为 `results/deployment/receiver_console.md`。以后并行调优时再决定线程和 worker 数，不让多进程同时争用全部核心。

隐藏窗口与禁止绘图不同：`defaultFigureVisible='off'` 保留 PNG 导出；`doPlot=false` 会关闭对应图件输出。需要导航时将长度增到 60–120 秒、`acqSatelliteList=1:63`、`numberOfChannels=63`，打开 `doNavigation/doNmea`，并换新 `tag/outDir`。

### 6.3 Web UI

```powershell
Set-Location -LiteralPath E:\GNSS\B2a
$env:B2A_MATLAB = 'C:\Program Files\MATLAB\R2026a\bin\matlab.exe'
python launch_b2a_ui.py --host 127.0.0.1 --port 8787 --no-browser
```

Web 界面是 Python 通过子进程启动 MATLAB，不需要 MATLAB desktop 或 Engine。`--no-browser` 只控制 Python 是否自动打开网页；接收机图件和百度浏览器另由执行参数控制。当前 Web schema 未暴露 TF 参数，TF 用 `runFromJsonConfig/runFromSettings` 的配置入口。

服务器通过 OpenSSH 转发供本地浏览器使用：

```text
ssh -N -L 8787:127.0.0.1:8787 user@server
```

本地打开 `http://127.0.0.1:8787`。网页填写的是服务器 IF 路径。服务没有多用户鉴权机制，保持本机监听和 SSH 转发即可；不必将 8787 直接开放到公网。

若 MATLAB 许可仅通过 `MLM_LICENSE_FILE/LM_LICENSE_FILE` 环境变量配置，需核对 Web runner 的 `_matlab_clean_env`：现有允许列表未转发这两个变量。可先用正常 PowerShell 环境直接运行 CLI，或按目标许可方式完善启动环境后再验收 Web。

## 7. 完整验收清单

按顺序完成以下检查，长实验放在最后：

| 阶段 | 检查内容 | 通过标准 |
| --- | --- | --- |
| 代码 | 分支、提交号、关键程序、Git 状态 | 当前 TF 前端和两组外部批处理都存在。 |
| 环境 | MATLAB/工具箱、Python、许可、路径 | 所用函数来自目标 MATLAB 和当前项目。 |
| MEX | 重编译、`which -all`、实际调用、数值对照 | 两个 `.mexw64` 可加载且结果通过验收。 |
| 基础测试 | 入口、TF、NH 重捕、NMEA、数值诊断 | 测试无失败。 |
| 5 秒 PB/TF | 同一 IF、同一 PRN 与独立输出目录 | 捕获/跟踪完成，配置和前端选择符合预期。 |
| 60–120 秒 | 全星捕获、多星跟踪、导航、NMEA | 实际产生定位历元、合理 UTC、NMEA 与图件。 |
| 地图 | 百度 AK/网络，卫星缓存/DME 点 | 轨迹、站址、底图、配色与空间范围对应。 |
| S4 | 独立项目、资源、UTC 锚点、≥180 秒弧段 | 三种 S4 数值、窗口与图件对应原结果。 |
| 长实验/并行 | 磁盘、内存、2–6 workers | 完整完成后再扩展到其他实验。 |

基础测试入口：

```matlab
setupPaths
r = runtests({'tests/test_config_entrypoints.m', ...
              'tests/test_tf_frontend.m', ...
              'tests/test_NH_stateMachine_reacq.m', ...
              'tests/test_nmea_sentences.m', ...
              'tests/test_algorithm_diagnostics.m'});
assertSuccess(r)
test_batch_dir_for_one_settings
```

核心结果检查：`report.json`、`ui_results.mat`、`temp/Trk_Prn_*_final.mat`、完整运行 MAT、`pvt.nmea`、`figures/trkResult`、`figures/navResult`。`report.ok=true` 不单独证明有定位，需检查 `navSummary.nFixes` 和导航数组；至少四颗卫星具有可用电文/星历才能形成相应定位解。

三种 S4 的入口与输出见 [PB-S4 批处理说明](../batch/data1020_pb_s4/RUN.md)。保持已确认的配置，包括本组实验的 `forceHardwareValid=true`；它是实验配置，不是新服务器硬件标定。接收机在线 S4 与外部 `S4_proposed/S4_conventional/S4_obs` 是两个处理层。

已完成跟踪可回放导航/S4。普通跟踪 chunk 不含完整环路恢复状态；中断通道不能靠复制最后一个 chunk 就任意续跑，现有恢复驱动会从捕获初值重跑该通道。

## 8. 迁移完成后保留的记录

将以下信息保存在目标结果目录的一份 Markdown 环境记录中：代码提交号、MATLAB 版本、Windows 版本、工具箱列表、C 编译器版本、两个 MEX 路径与 SHA-256、IF 文件大小/校验值、原始配置副本、短测和完整导航验收结果。由 `Get-FileHash` 生成 MEX 指纹，不把新二进制强制加入 Git。

本说明给出目标机操作步骤；本次文档提交没有在另一台服务器上执行安装、重编译或接收机验收。Windows/MEX 既有验证记录见 [R2026a 兼容说明](r2026a_compatibility.md)，项目总体迁移范围见 [通用迁移指南](迁移与全功能运行指南_20261013.md)。
