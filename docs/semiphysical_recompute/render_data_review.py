"""Render the current audited case metrics; never declare pending cases done."""
from pathlib import Path
import datetime as dt
import json
import statistics
import csv

root = Path(__file__).resolve().parents[2]
run = root / 'results/semiphysical_recompute/20260930_restart_isolated'
review = run / 'review'
review.mkdir(exist_ok=True)
state = json.loads((run / 'supervisor.json').read_text('utf-8'))
records = []
rows = []
detail = []
config_rows = []
cno_rows = []
scint_rows = []
probe_rows = []
probe_path = run / 'rf_parameter_probes.json'
if probe_path.exists():
    probes = json.loads(probe_path.read_text('utf-8'))
    for case_probe in probes['cases']:
        windows = case_probe['windows']
        before = statistics.mean(w['inputRms'] for w in windows)
        after = statistics.mean(w['postRmsAtThresholdMinus3NominalPlus3Db'][1] for w in windows)
        duties = [100*statistics.mean(w['dutyAtThresholdMinus3NominalPlus3Db'][i] for w in windows)
                  for i in range(3)]
        probe_rows.append(f"| {case_probe['case']} | {before:.2f} | {after:.2f} | "
                          f"{duties[0]:.3f} / {duties[1]:.3f} / {duties[2]:.3f} |")
lag_path = review / 'relative_lag_hypotheses.json'
lags = json.loads(lag_path.read_text('utf-8'))['cases'] if lag_path.exists() else []
if isinstance(lags, dict):
    lags = [lags]
lag_by_name = {x['case']: x for x in lags}
for case in state['cases']:
    name = case['case']
    path = review / name / 'data_review.json'
    if not path.exists():
        rows.append(f"| {name} | {case['status']} | — | — | — | — | — |")
        continue
    r = json.loads(path.read_text('utf-8'))
    p = r['prn11']; n = r['navigation']; tracks = r['tracks']
    record = dict(case=name, status=case['status'], outputDir=case['outputDir'],
                  validationOK=r['validation']['ok'],
                  satellites=len(tracks), fixes=n['validFixes'],
                  completeTracks=sum(t['samples'] == 715000 and t['finiteSamples'] == 715000
                                     and t['timestampSamples'] == 715000
                                     and t['nonIncreasingAbsoluteSamples'] == 0 for t in tracks),
                  prn11ReacqMs=p['reacqMs'], medianCNo=p['cnoTotalDbHz']['median'],
                  pbDutyPercent=100*p['pbDuty']['mean'],
                  residualRmsMedianM=n['raimResidualRmsM']['median'],
                  horizontalScatterP95M=n['horizontalScatterM']['p95'],
                  verticalScatterStdM=n['enuStdM'][2],
                  frameAudit=p['navFrameAudit'], dopAudit=n['dopAudit'])
    record['cnoPatchAudit'] = [dict(PRN=t['PRN'], **t['cnoPatchAudit']) for t in tracks]
    record['allSatelliteReacqMs'] = sum(t['reacqMs'] for t in tracks)
    record['invalidNavigationEpochs'] = n.get('invalidEpochs', [])
    parameter = r['parameters']
    config_rows.append(f"| {name} | {parameter['bandwidthMHz']:g} | {parameter['thresholdDbm']:g} | "
                       f"{parameter['thresholdAmplitude']:.3f} | {parameter['startOffsetMs']:g} |")
    cno_rows.append(f"| {name} | {sum(t['cnoPatchAudit']['changedWindows'] for t in tracks)} | "
                    f"{sum(t['cnoPatchAudit']['belowThresholdWindows'] for t in tracks)} | "
                    f"{min(t['cnoPatchAudit']['minimumFixedTotalCNo'] for t in tracks):.2f} |")
    corrected = review / name / 'scint_replay_summary.json'
    if corrected.exists():
        record['scintReplay'] = json.loads(corrected.read_text('utf-8'))
        with (review / name / 'prn11_scint_corrected.csv').open(newline='', encoding='utf-8-sig') as fh:
            scint_data = [row for row in csv.DictReader(fh) if row['Valid'] == '1']
        zero_count = sum(float(row['S4GaussianCorrected']) == 0 for row in scint_data)
        record['scintReplay']['zeroCorrectedOutputs'] = zero_count
        sc = record['scintReplay']
        scint_rows.append(f"| {name} | {sc['validOutputs']} / {sc['totalOutputs']} | "
                          f"{sc['rawMedian']:.4f} | {sc['correctedMedian']:.4f} | {zero_count} |")
    if name in lag_by_name:
        record['relativeLagHypothesis'] = lag_by_name[name]
    records.append(record)
    rows.append(f"| {name} | {case['status']} | {n['validFixes']} | {p['cnoTotalDbHz']['median']:.2f} | "
                f"{100*p['pbDuty']['mean']:.3f} | {p['reacqMs']} | {n['raimResidualRmsM']['median']:.3f} |")
    a = p['navFrameAudit']; dop = n['dopAudit']
    detail.append(f"- **{name}**：完整跟踪 {record['completeTracks']}/{len(tracks)} 星；"
                  f"全星重捕获累计 {record['allSatelliteReacqMs']} ms；"
                  f"水平散布 P95={record['horizontalScatterP95M']:.3f} m，垂直标准差="
                  f"{record['verticalScatterStdM']:.3f} m；PRN 11 可用导航帧 "
                  f"{a['receiverUsableFrames']}/{a['scheduledCompleteFrames']}，CRC 通过帧 TOW 不连续数 "
                  f"{a['towMismatchesAmongCrcPass']}。ENU 修正后的 HDOP/VDOP 中位数 "
                  f"{dop['enuCorrectedMedian'][2]:.3f}/{dop['enuCorrectedMedian'][3]:.3f}。")

complete = sum(c['status'] == 'done' for c in state['cases'])
applied_path = run / 'fixes_applied.json'
applied = json.loads(applied_path.read_text('utf-8')) if applied_path.exists() else None
regression_path = run / 'post_apply_checks.json'
regression = json.loads(regression_path.read_text('utf-8')) if regression_path.exists() else None
release_checks = []
offset_path = review / 'dme_free/start_offset_sensitivity.json'
offset_check = json.loads(offset_path.read_text('utf-8')) if offset_path.exists() else None
for release in ('2026a', '2024b'):
    check_path = run / f'post_apply_{release}.json'
    if check_path.exists():
        release_checks.append(json.loads(check_path.read_text('utf-8')))
summary = dict(generatedAt=dt.datetime.now().astimezone().isoformat(),
               experimentsComplete=complete == 5, auditedCases=len(records),
               sourceFixesApplied=applied is not None, postApplyChecks=regression,
               releaseChecks=release_checks, startOffsetSensitivity=offset_check, cases=records)
(review / 'algorithm_review.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')

lines = [
    '# 五组半物理实验：结果与参数算法审查', '',
    f"更新时间：{summary['generatedAt']}。五组完成并校验 {complete}/5，已完成数据审查 {len(records)}/5。", '',
    '各组使用原实验配置：715 秒、25 MHz、int16 复 IQ、1 ms 积分；FLL 开启、KF 关闭。'
    '无 DME 复用已验证的完整结果，其余四组使用独立 R2024b 进程重算。', '',
    '| 组别 | 状态 | 有效定位历元 | PRN11 C/N₀中位数 dB-Hz | PB 平均占空比 % | PRN11重捕获 ms | RAIM残差RMS中位数 m |',
    '|---|---|---:|---:|---:|---:|---:|', *rows, '',
    'C/N₀、PB 和残差采用记录第 150 秒之后的数据。重捕获和定位历元统计覆盖完整记录。', '',
    '## 完整性与定位质量', '', *detail, '',
    '散布以各组自身的中位位置为参考，尚无模拟器坐标真值，不能称为绝对定位精度。'
    '有效 PVT 连续不代表导航比特无误码；目前 B-CNAV2 只对系统位作硬判决/CRC，未实现 LDPC 纠错。', '',
    '## 参数判断', '',
    '| 组别 | IFBandwidth MHz | PB 门限 dBm | PB 数字幅度门限 | startOffset ms |',
    '|---|---:|---:|---:|---:|', *config_rows, '',
    '- PB 数字幅度门限反算 dBm 与配置一致。七个分布在全记录中的 RF 抽样窗口均未观察到 ADC 顶格值；全程 PB 占空比见表。',
    '- 保留原 17.5/18 MHz 带宽差异、PLL 50/30 Hz 与 DLL 10/2 Hz 配置。当前数据用于检查可用性和稳定性，不在缺少真值的条件下宣称这些参数最优。',
    '- 强闪烁段的 PLL 鉴别器起伏明显增大（比较图中 1 秒 RMS 可接近 50°）；无重捕获不等于无载波周跳。本次没有注入相位真值，未把定位连续性当作载波相位连续性的证明。',
    '- 本离线路径的 IFBandwidth 仅用于 DLL 热噪声诊断，不会改变已录制 RF 的实际频带。',
    '- RAIM 原门限为 RMS 80 m、最大残差 200 m；它们远宽于本组实测残差，仅通过这些门限不能证明绝对精度。',
    '- startOffset 仅初始化接收机时间，不是 RF 闪烁注入偏移。不得将下述数据驱动延迟直接写入该参数。', '',
    *([f"对同一无 DME 组相关器作独立导航重放，将 startOffset 从 {offset_check['originalOffsetMs']:g} ms 改为 "
       f"{offset_check['replayOffsetMs']:g} ms，有效定位仍为 {offset_check['replayValidFixes']} 个；"
       f"位置最大差 {offset_check['maxPositionDifferenceM']:.3g} m，校正后接收机时间最大差 "
       f"{offset_check['maxReceiverTimeDifferenceSec']:.3g} s。此数据中该差异被接收机钟差解算吸收。", '']
      if offset_check else []),
    'RF 抽样统计（七个 20 ms 窗口的平均值；RMS 单位为数字采样单位）：', '',
    '| 组别 | PB 前 RMS | 原门限 PB 后 RMS | 门限 −3 / 原值 / +3 dB 的消隐占比 % |',
    '|---|---:|---:|---:|', *probe_rows, '',
    '干扰组 PB 前幅度差别较大，消隐后 RMS 接近，说明强脉冲消隐在起作用。'
    '消隐占比与残余 RMS 不足以确定最优门限；改变门限还需比较同一 RF 段的相关器信号保留、'
    'C/N₀ 和定位表现。这次完整重算没有根据抽样结果调整原门限。', '',
    '## 已复现的算法问题', '',
    '- HDOP/VDOP：ECEF 协方差必须转为当地 ENU 后取水平/垂直分量；PVT 坐标及 GDOP/PDOP/TDOP 不因此改变。',
    '- C/N₀：负根号后取复数绝对值会生成假载波估计；零功率窗口必须计入失锁判断，不能混同尚无观测的 −1 哨兵。',
    '- S4：输入应为强度，原在线代码使用电压幅度；同时需要屏蔽完整窗口之前的滤波暂态，避免将无效 NaN 写成 0。',
    '- S4 热噪声项需匹配原生 1 ms 积分。修正后的高斯噪声近似仍不能自动代表 DME/PB 后的残差模型，因此同时保存未经热噪声扣除的强度 S4。',
    '- PLL 热噪声诊断应使用导频支路 C/N₀，而非数据与导频合计值。', '',
    '下表覆盖每组全部已捕获卫星的 200 ms C/N₀ 观测窗，使用原相关器重新计算修正后的估计。', '',
    '| 组别 | 被修正的窗口数 | 修正后低于 25 dB-Hz 的窗口数 | 修正后最低总 C/N₀ dB-Hz |',
    '|---|---:|---:|---:|', *cno_rows, '',
    'PRN 11 的 S4 独立重放（60 秒窗口、5 秒输出、150 秒预热）：', '',
    '| 组别 | 有效 / 总输出数 | 原始强度 S4 中位数 | 近似去噪 S4 中位数 | 近似去噪后截为 0 的输出数 |',
    '|---|---:|---:|---:|---:|', *scint_rows, '',
    '噪声项采用信号功率均值归一化的强信号近似，并使用最近一次 C/N₀。'
    '深衰落时的有限信噪比、60 秒窗内的非平稳噪声和 PB 后相关性仍需进一步建模；'
    '截为 0 只表示该近似下扣除项大于原始方差，不能据此断言该窗口没有闪烁。', '',
    ('修复已应用到接收机源码，原计算结果完整保留。' if applied else
     '修复仍在独立 candidate_code 目录；完整五组冻结计算结束前不会应用到接收机源码。'), '',
    '回归检查覆盖文件尾部/不完整 IQ、跟踪结果保存、分段 TOW、重捕获缺口、伪距采样范围、'
    '时间倒序、NMEA、C/N₀、ENU DOP、S4 强度与预热、PLL 热噪声支路，以及可选类的基础接口。'
    'KF 在这五组中关闭，因此本次结果不代表 KF 动态性能验证。', '',
    *[f"- 正式源码 MATLAB R{c['release']}：{c['passed']} 项通过，{c['failed']} 项失败，"
      f"{c['incomplete']} 项未完成；批处理编排测试 {'通过' if c['batchOrchestration']['ok'] else '失败'}。"
      for c in release_checks], '',
    '## 相对时间匹配（候选结论）', '',
    '以下为相对于无 DME 记录的整数秒延迟估计；正值表示同一特征在该记录中更晚出现。'
    '功率与 C/N₀ 分别估计，尚需独立注入记录/真值确认。', '',
    '| 组别 | 功率延迟 s | 功率相关系数 | C/N₀延迟 s | C/N₀相关系数 |',
    '|---|---:|---:|---:|---:|',
]
for a in lags:
    lines.append(f"| {a['case']} | {a['powerLagSec']} | {a['powerCorrelation']:.4f} | {a['cnoLagSec']} | {a['cnoCorrelation']:.4f} |")
lines += ['', '## 图与逐组文件', '',
          '![跟踪比较](tracking_comparison.png)', '',
          '![稳态统计](statistics_comparison.png)', '',
          '每组 review 子目录保存 data_review.json、prn11_scint_corrected.csv/.mat、scint_replay_summary.json，以及 DOP 修正后的 navigation_corrected.mat、pvt_corrected.nmea。'
          '修复后的 S4 为从原始相关器重放的独立诊断结果，未覆盖原 MAT。', '',
          f'[详细调试记录]({(root / "docs/semiphysical_recompute/调试与算法审查_20260930.md").as_posix()})。', '',
          '定义依据：[ESA S4 定义](https://swe.ssa.esa.int/tio_sci)、'
          '[ESA DOP/ENU 定义](https://gssc.esa.int/navipedia/index.php/Positioning_Error)。', '']
(review / '五组结果与参数算法审查.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'Report updated: completed={complete}/5 audited={len(records)}/5 applied={applied is not None}')
