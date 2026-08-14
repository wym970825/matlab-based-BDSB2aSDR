%% BDS B2a SDR 快速指南
% 本文件是可搜索的 MATLAB 示例手册。所有示例均被注释，直接运行本文件
% 不会启动长时间接收机任务；选中需要的示例行后执行即可。
%
% 项目初始化：
%   cd('F:\matlab-GNSSsdr\BDS\B2a')
%   setupPaths

%% 1. 全流程入口与统一输出
% Web UI：在系统命令行运行 python launch_b2a_ui.py。
%
% 使用原始默认设置：
%   run('init_B2a.m')
%
% MATLAB settings 入口：
%   settings = initSettings('msToProcess', 60000, ...
%       'acqSatelliteList', 1:60);
%   tag = char(string(datetime('now'), 'yyMMdd_HHmmss'));
%   report = runFromSettings(settings, ...
%       'outDir', fullfile('results', 'ui', tag), ...
%       'tag', tag, 'doBaiduMap', false, 'closeFigures', true);
%
% JSON 入口：
%   report = runFromJsonConfig('batch/b2a_ui_config.json');
%
% 输出固定包含 temp/ 和 figures/AcqResult、trkResult、navResult；完整
% 目录契约见 docs/product_catalog.md。

%% 2. 目录批处理
% 一个 JSON 处理整个目录：
%   report = batchDirForOneSettings( ...
%       'F:\Data\ExpKLHP\X310_IFData', ...
%       'batch\b2a_ui_config.json', ...
%       'Recursive', false, 'ContinueOnError', true);
%
% 快速验证调度和输出结构，不读取真实 IF：
%   result = test_batch_dir_for_one_settings();

%% 3. smoke_ 入口
% smoke_acquisition：只跑捕获，默认搜索 PRN 1:63，并报告最强卫星。
%   a = smoke_acquisition('fullSky', true);
%
% smoke_tracking：单星短跟踪，不做定位。
%   t = smoke_tracking('msToProcess', 10000, ...
%       'acqSatelliteList', 36);
%
% smoke_pvt：至少 4 星、约 38 s 以上的捕获/跟踪/PVT/图片/性能报告。
%   p = smoke_pvt('msToProcess', 60000, ...
%       'acqSatelliteList', [19 22 36 39 40 45]);
%
% smoke_pullin_fll_off：串行对比问题卫星 FLL 开/关的牵引结果。
%   r = smoke_pullin_fll_off('msToProcess', 5000, ...
%       'prnList', [25 27 32 23]);
%
% smoke_nav_plot_baidu：从已有 navigation MAT 重放 PVT 图片/百度地图。
%   outDir = smoke_nav_plot_baidu('matPath', 'navigation_replay.mat', ...
%       'openBaiduMap', false);

%% 4. test_ 入口
% 批处理调度与统一输出骨架：
%   test_batch_dir_for_one_settings();
%
% 跨 UTM 分区时连续的 ECEF->ENU 航迹：
%   runtests('tests/test_nav_track_time_order.m');
%
% NH 状态机连续低 C/N0 重捕获门控：
%   runtests('tests/test_NH_stateMachine_reacq.m');
%
% NMEA GGA/GSA/GSV/ZDA、RAIM 筛选和校验和：
%   runtests('tests/test_nmea_sentences.m');
%
% 长跟踪分块/最终文件的内存安全序列化：
%   runtests('tests/test_track_result_serialization.m');

%% 5. 从跟踪结果直接定位
% 这是当前正式入口；不重新读取 IF，不重新捕获或跟踪。resultPath 可以是
% 运行根目录、其 temp 子目录，或直接含 final.mat 的旧时间戳目录。
%   report = runNavigationFromTracking( ...
%       'results\ui\260813_235004', ...
%       'PlotNavigation', true, 'ForceNmea', true);
%
% 指定另一份 JSON 配置，更新已有工程的 PVT/NMEA：
%   report = runNavigationFromTracking(runDir, ...
%       'Config', 'batch\b2a_ui_config.json', ...
%       'OutputFile', 'pvt.nmea', ...
%       'FigureDir', fullfile(runDir, 'figures', 'navResult'));
%
% 输出为 pvt.nmea、navigation_replay.mat、
% navigation_satellite_usage.csv 和 figures/navResult/*.png。NMEA 采用临时文件
% 后原子替换，定位失败时不会破坏已有 pvt.nmea。

%% 6. 跟踪通道可视化回放
% 推荐入口会逐文件加载 final.mat、逐通道保存并关闭图，适合长跟踪结果：
%   report = replayTrackingChannels('results\ui\260813_235004', ...
%       'Visible', false, 'Overwrite', true, 'MaxPlotPoints', 20000);
%
% 只看指定卫星并保留可编辑 FIG：
%   report = replayTrackingChannels(runDir, ...
%       'PRNs', [36 39], 'Visible', true, 'SaveFigure', true);
%
% 已在内存中有 trackResults 时：
%   report = exportTrackingFiguresSequential(trackResults, settings, ...
%       fullfile(runDir, 'figures', 'trkResult'), 'Visible', false);
%
% 批量脚本包装器：设置 trackReplayRoot/trackReplayOptions 后运行
% tests/debug_plot_all_channe.m。

%% 7. 捕获结果可视化回放
% 从 ui_results.mat、run_B2a_*.mat 或 acq_results.mat 重放捕获结果：
%   report = replayAcquisitionChannels(runDir, ...
%       'Visible', false, 'Overwrite', true, 'FontSize', 16);
%
% 只显示指定 PRN：
%   report = replayAcquisitionChannels(runDir, ...
%       'PRNs', [19 36 39], 'Visible', true);
%
% 批量脚本包装器：设置 acqReplayRoot/acqReplayOptions 后运行
% tests/debug_plot_Acq_channel.m。

%% 8. 定位与通用绘图函数
% 当前 PVT 图片统一由 plotNavPost 生成：ENU 位移、速度、DOP、天空图和
% LLA 航迹。离线使用时关闭百度地图和浏览器：
%   settings.plotNavPost = true;
%   settings.plotBaiduMap = false;
%   figs = plotNavPost(navSolutions, settings, ...
%       'saveDir', fullfile(runDir, 'figures', 'navResult'), ...
%       'doLegacy', false, 'openBaiduMap', false, ...
%       'openBaiduBrowser', false);
%
% 捕获结果已有于内存时：
%   plotAcquisition(acqResults, settings.acqSatelliteList);
%
% 旧的 plotTracking、plotTracking_NHSMKF 和 plotNavigation 仅用于交互式
% 诊断或历史对比；长任务和产品导出优先使用上述 sequential/replay 入口。
