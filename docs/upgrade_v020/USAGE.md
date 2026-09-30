# v0.2.0 前端配置与复现

本版实现 R3 批复的 TF v1。前端位置为捕获、相关器和跟踪之前，PB 与 TF 互斥。旧配置没有 `Frontend.mode` 时仍按 `EnablePB` 选择 PB 或旁路。

## 配置

在已有数据集 JSON 的副本中加入以下字段，其他采样、门限、环路和监测设置沿用原配置：

```json
"Frontend": {
  "mode": "tf_v1",
  "TF": {
    "centerHz": -450000,
    "stopbandWidthHz": 400000,
    "transitionEachSideHz": 150000,
    "firTaps": null,
    "referenceTaps": 641,
    "referenceSamplingFreqHz": 25000000,
    "kaiserBeta": 5.65326,
    "thresholdAmplitude": null,
    "triangleSpanUs": 12,
    "pulseTailMarginUs": 2,
    "boundaryPolicy": "raw_with_invalid_flag"
  }
}
```

- `mode` 可为 `off`、`pb`、`tf_v1`；`tf_v2` 明确报未实现。显式 mode 优先于 `EnablePB`。
- 带宽是**深阻带总宽**，可设 400000 或 600000 Hz，另有每侧 150000 Hz 过渡带。
- TF 输入必须为 `fileType=2`，`dataType=int8/int16`，文件交织顺序 `I0,Q0,I1,Q1,...`，复数为 `I+jQ`；每个复样本占 2/4 字节。int16 默认沿用本机小端，也支持 `machineFormat` 指定源数据字节序。
- 采样率读取 `samplingFreq`。未指定抽头时，`D=max(1,ceil(320*fs/25e6))`、`L=2D+1`，25/30.69 MHz 分别为 641/787 抽头。显式奇数 `firTaps>=3` 优先；改变长度需重新检验频响。
- 阈值优先使用 `Frontend.TF.thresholdAmplitude`，否则依次使用 `PB_settings.Th_static_tracking`、`Th_static`。单位为输入 ADC 幅度，转换为 double 后不归一化，不因位宽变化自动套用或缩放门限。
- 用固定原始输入检测权重，各阶段一致。FIR 在请求段两边读取真实 halo，移除 D 的索引延迟后返回同一物理样本区间。25 MHz 的默认 D/K/P/H 为 320/150/50/670。
- 无检测时直接复制原始输入。文件边缘上下文不足时保留原值并标记无效；跟踪在无效积分前结束，不将其填零送入 C/N0 或 S4。捕获从首个有完整上下文的样本开始并记录起点。

## MATLAB 入口

```matlab
setupPaths
report = runFromJsonConfig('path/to/copied_config.json', ...
    'outDir','results/my_unique_run','closeFigures',true);

% 完整 settings 入口同样支持 Frontend：
settings.Frontend = struct('mode','tf_v1', ...
    'TF',struct('stopbandWidthHz',600000));
report = runFromSettings(settings);

% 原始 IF 与所选前端的频谱探针：
probe = runProbeIf('path/to/copied_config.json', ...
    'outDir','results/my_unique_probe');
```

本轮未新增网页配置控件；使用 JSON 或 MATLAB settings 指定 TF，避免仅修改 `EnablePB` 误以为已选择 TF。

## 可复现实验与测试

```matlab
setupPaths
addpath(fullfile(pwd,'tests'))
r = runtests('tests/test_tf_frontend.m'); assert(all([r.Passed]))
verify_tf_correlation_fidelity('results/my_unique_correlation_check');

% 四个带干扰数据集索引为 2:5；串行单星 PRN 11：
run_tf_semiphysical_validation(4,30000,{'pb','tf400','tf600'}, ...
    'results/my_unique_short_run');
run_tf_semiphysical_validation(4,715000,{'pb','tf400','tf600'}, ...
    'results/my_unique_full_run');
```

驱动拒绝覆盖已有目录，保存配置副本、源码指纹、MATLAB 版本、输入文件属性、日志和完整性检查结果。原始五份 JSON 不修改；仅副本覆盖单星、串行、长度和导航/绘图开关。运行失败时清单保留失败状态。完整跟踪归档为 `run_B2a_<tag>.mat`；`ui_results.mat` 是轻量网页产品，不包含完整跟踪对象。

## 输出与解释

`trackResults.frontendInfo` 保存实际生效配置、阈值来源、D/K/P/H、系数及哈希。每个 1 ms 实际核心区间保存 `frontendSampleCount/ValidCount/BoundaryFlag/DetectorDuty/MeanWeight/MeanWeightSquared/WeightSupportFraction`；`absoluteSample` 是零起始的文件复样本编号，结束位置为起点加样本数减一，halo 不计入统计。

TF 权重不冒充 PB 的 PDC；PB 原有字段与数值行为保留。C/N0 和 S4 仍由处理后的相关量及原有计算器产生，没有按权重除法补偿。FIR 索引对齐不等于相关峰、相位和 S4 无偏；相关保真度及真实跟踪结果须一起解释。单星实验不要求产生多星 PVT。400/600 kHz 的结论只覆盖实际验证的数据集和时段。

本地版本控制、实际验收数据及未验证范围见 [项目记录](PROJECT.md) 和完成后的验收报告。没有向 GitHub 推送。
