"""Build the Chinese Markdown report from completed MATLAB comparison tables."""
from pathlib import Path
from statistics import median
import hashlib
import json
import re
import shutil
import sys

sys.stdout.reconfigure(encoding='utf-8')

REPO = Path('F:/matlab-GNSSsdr/BDS/B2a')
ROOT = REPO / 'results/data1020/20261010_tf_h0_20s'


def read_table(name):
    lines = [line for line in (ROOT / name).read_text(encoding='utf-8').splitlines() if line.startswith('|')]
    values = [[x.strip() for x in line.strip('|').split('|')] for line in lines]
    return [dict(zip(values[0], row)) for row in values[2:]]


def md_table(headers, rows):
    return '\n'.join(['| ' + ' | '.join(headers) + ' |', '| ' + ' | '.join(['---'] * len(headers)) + ' |'] +
                     ['| ' + ' | '.join(map(str, row)) + ' |' for row in rows])


def number(row, field):
    return float(row[field])


def signed(value, places=3):
    return f'{value:+.{places}f}'


summary = read_table('cno_summary.md')
paired = read_table('paired_cno.md')
effects = read_table('analysis/direct_effects.md')
duty = read_table('analysis/sample_weighted_duty.md')
spectra = read_table('spectral_estimates.md')
audit = read_table('analysis/independent_audit.md')
excluded = read_table('analysis/excluded_windows.md')
manifest = json.loads((ROOT.parent / '20261009_pb_tf_comparison/manifest.json').read_text(encoding='utf-8'))
entries = {int(e['experimentNumber']): e for e in manifest['entries']}
ids = [2, 4, 5]
labels = ['PB_original', 'TF_original_800k_3us', 'TF_H0_800k_3us'] + [f'TF_H0_spectrum_{s}us' for s in range(1, 6)]
display = ['原 PB', '原 TF：800 kHz / 3 μs', 'H0 TF：800 kHz / 3 μs'] + [f'H0 谱带宽 / {s} μs' for s in range(1, 6)]
index = {(int(r['Experiment']), r['Variant']): r for r in summary}
effect_index = {(int(r['Experiment']), r['Contrast']): r for r in effects}
paired_index = {(int(r['Experiment']), r['Variant'], int(r['PRN'])): r for r in paired}

assert len(audit) == 72 and all(r['MatchesSaved'] == 'true' and r['Samples'] == '20000' and r['Reacq'] == '0' for r in audit)
assert len(excluded) == 21 and all(r['Experiment'] == '5' and r['PRN'] == '27' and r['PilotCno'] == '-Inf' for r in excluded)
hash_rows = []
for r in read_table('source_hashes.md'):
    current = hashlib.sha256((REPO / r['File']).read_bytes()).hexdigest()
    assert current == r['SHA-256']
    hash_rows.append([r['File'], current, '一致'])
(ROOT / 'analysis/source_hash_recheck.md').write_text('# 接收机核心文件复核\n\n' + md_table(['文件', 'SHA-256', '与运行前记录比较'], hash_rows) + '\n', encoding='utf-8')

source_rows = [[f'{i:02d}', entries[i]['sourceId'], f"{entries[i]['centerFrequencyHz']/1e6:.2f}",
                entries[i]['utcStart'].replace('T', ' ').replace('Z', ''), '怀柔 / 1170 MHz'] for i in ids]
summary_rows = []
for label, title in zip(labels, display):
    row = [title]
    for i in ids:
        r = index[i, label]
        row.extend([signed(number(r, 'MedianSatelliteDeltaB2a'), 4), signed(number(r, 'MedianSatelliteDeltaPilot'), 4)])
    summary_rows.append(row)

parameter_rows = []
for r in spectra:
    i = int(r['Experiment'])
    width99 = (number(r, 'Excess99HighHz') - number(r, 'Excess99LowHz')) / 1e3
    parameter_rows.append([f'{i:02d}', f"{entries[i]['staticPBAmplitude']:.3f}", f"{number(r, 'DetectorAmplitude'):.3f}",
                           f"{number(r, 'IterativeH0Variance'):.3f}", f"{number(r, 'EstimatedDmeCenterHz')/1e6:.6f}",
                           f'{width99:.1f}', f"{number(r, 'NotchFullWidthHz')/1e3:.0f}"])
noise_rows = [[f"{int(r['Experiment']):02d}", f"{number(r, 'WelchNoisePsdAdc2PerHz'):.6g}",
               f"{number(r, 'WelchFlatFullBandVariance'):.3f}", f"{number(r, 'GaussianH0MeasuredPfa'):.6f}"] for r in spectra]
contrast_names = [('H0_minus_originalTF', '仅更新 H0 门限'), ('spectrum3_minus_H0800', '800 kHz → 实测谱中心/全宽，均为 H0、3 μs'),
                  ('spectrum1_minus_originalTF', '新谱配置 1 μs → 相对原 TF 的总变化')]
contrast_rows = []
for name, title in contrast_names:
    row = [title]
    for i in ids:
        r = effect_index[i, name]
        row.append(f"{signed(number(r, 'DeltaB2a'), 4)} / {signed(number(r, 'DeltaPilot'), 4)}")
    contrast_rows.append(row)

def duty_value(i, label, field):
    return median(number(r, field) for r in duty if int(r['Experiment']) == i and r['Variant'] == label)

duty_rows = []
for i in ids:
    duty_rows.append([f'{i:02d}', f"{duty_value(i, labels[1], 'DetectorPercent'):.3f}",
                      f"{duty_value(i, labels[2], 'DetectorPercent'):.3f}", f"{duty_value(i, labels[1], 'MeanWeightPercent'):.3f}",
                      f"{duty_value(i, labels[2], 'MeanWeightPercent'):.3f}", f"{duty_value(i, labels[3], 'MeanWeightPercent'):.3f}",
                      f"{duty_value(i, labels[7], 'MeanWeightPercent'):.3f}"])
edge_rows = []
for span in [1, 2, 3, 4, 5]:
    row = [str(span)]
    for i in ids:
        if span == 3:
            row.append('0 / 0')
        else:
            r = effect_index[i, f'edge{span}_minus_edge3']
            row.append(f"{signed(number(r, 'DeltaB2a'), 5)} / {signed(number(r, 'DeltaPilot'), 5)}")
    edge_rows.append(row)
star_rows = []
for i in ids:
    for prn in [27, 38, 41]:
        p = paired_index[i, labels[0], prn]
        old = paired_index[i, labels[1], prn]
        new = paired_index[i, labels[3], prn]
        star_rows.append([f'{i:02d}', str(prn), p['CommonWindows'], f"{number(p, 'B2aCno'):.3f}",
                          signed(number(old, 'DeltaB2aVsPB')), signed(number(new, 'DeltaB2aVsPB')),
                          signed(number(new, 'DeltaPilotVsPB'))])

report = f'''# PB / TF H0 短测参数效果分析报告

日期：2026-10-10。数据采集日期：2022-10-20。结果目录：`results/data1020/20261010_tf_h0_20s`。

## 1. 主要结论

02、04 组中，TF 的 B2a 载噪比估计整体高于原 PB，典型提升约 **0.28、0.22 dB-Hz**。05 组中，所有已测 TF 配置均低于原 PB；使用实测谱带宽后改善了原 TF，但没有反超 PB。

本轮最有效的参数改动是 **05 组将陷波全宽从 800 kHz 扩到 1150 kHz，并采用实测中心**。保持 H0 门限和 3 μs 边缘窗不变，同一时刻直接配对得到 B2a / Pilot 提升 **0.3341 / 0.3098 dB-Hz**。02、04 组估计全宽为 500 kHz，相应谱配置改动带来的 B2a 提升仅为 0.0112、0.0022 dB-Hz。

将原幅度门限改为 H0 下每复样点虚警率 10⁻³ 的门限，没有增加载噪比：02、04、05 组 B2a 直接配对变化分别为 **−0.0114、−0.0125、−0.0352 dB-Hz**。同时，3 μs TF 平均作用权重由约 5% 上升到约 44%–48%。这一变化比微调边缘窗更值得关注。

1–5 μs 的载噪比差别很小，**1 μs 可作为下一轮统一的 TF 边缘窗**：平均作用权重最低，直接配对结果也没有显示延长到 5 μs 的收益。现有 `selection.md` 按相对 PB 的 B2a 汇总分数选出 02/4 μs、04/1 μs、05/1 μs；02 的 4 μs 优势只有千分之几 dB-Hz，不足以确立稳定最优值。

## 2. 数据、配置与统计口径

{md_table(['实验', '源文件短名', '采样中心 MHz', '原完整实验首次定位 UTC', '关联 DME'], source_rows)}

每组读取源文件开头约 20 秒，采样率均为 20 MHz，int16 交织复 IQ；比较 PRN 27、38、41。上表 UTC 用于关联原完整实验的地图与导航结果，并非本次 20 秒片段的精确起始 UTC。原位置图与导航入口见[六组实验索引](../20261009_pb_tf_comparison/index.html)。

每组包括八种配置：原 PB；原门限、800 kHz、3 μs 的原 TF；H0 门限、800 kHz、3 μs 的控制 TF；H0 门限和实测谱参数下的 1、2、3、4、5 μs TF。各配置复用原 PB 捕获初值，接收机跟踪环路相同。本次比较对象是跟踪阶段，未重新进行全星捕获和导航解算。

已从 72 个 `Trk_Prn_*_final.mat` 独立重建载噪比窗口，与原汇总逐项一致：**24 个配置全部完成，每条 20000 个毫秒记录，重捕事件为 0**。3 秒后所有记录均为 LONG 状态。原接收机五个核心文件的 SHA-256 与运行前记录一致，见[源文件复核](analysis/source_hash_recheck.md)。

载噪比沿用接收机 `Calc_CNo_PLD.m` 的 VSM 估计；B2a 为数据与导频线性 C/N₀ 相加后取对数，Pilot 为导频支路。存储值还经过相邻两次估计各 0.5 的平均。因此每 200 ms 更新一次，支持范围为 400 ms。

正式比较采用相对首个跟踪样点约 **5.2–20.0 秒的更新端点**；第一个端点的支持从约 4.8 秒开始。要求整个 400 ms 为 LONG、没有样点间断、B2a 与 Pilot 均为有限正值，八种配置取共同窗口，并检查物理端点相差小于 2 ms。通常每星 75 个窗口，05/PRN 27 为 72 个。

设同一实验、同一卫星的共同窗口为 Wₚ，报告的配置间变化为：

`Δ(A,B) = median_PRN {{ median_t∈Wₚ [C/N₀_A(t) − C/N₀_B(t)] }}`。

相对 PB 的配置分数为 Δ(A,PB)，参数单独作用则直接计算 Δ(A,B)。**两个配置的“相对 PB 分数之差”不等于它们的直接配对变化**，中位数不满足可加性。后文两种结果分别展示。窗口有时间重叠，本轮结论对应三组各 20 秒、每组三颗卫星，不把这些窗口当作独立重复试验。

## 3. H0 门限与实测陷波参数

### 3.1 冻结参数

{md_table(['实验', '原幅度门限 ADC', 'H0 幅度门限 ADC', 'H0 噪声功率 ADC²', '新 RF 中心 MHz', '主谱段 99% 宽度 kHz', '陷波全宽 kHz'], parameter_rows)}

H0 采用零均值圆对称复高斯噪声，令 σ² = E|n|²、Pfa = 10⁻³，则功率门限为 `−σ² ln(Pfa)`，幅度门限为 `sqrt(−σ² ln(Pfa))`。每组门限估计一次后冻结，五种边缘窗共用同一门限。

从 0–19.5 秒每隔 0.5 秒抽取一段 5 ms 原始 IQ，共 40 段、0.2 秒探针。Welch 使用 8192 点周期 Hann 窗、4096 点重叠、16384 点 FFT，输出双边复 IQ PSD。噪声参考频带为绝对 RF 1176.45 MHz ±5 MHz，扣除 1170、1173、1181 MHz 各自 ±1 MHz 和数字 DC ±25 kHz，保留频点 PSD 算术均值为 N₀。

{md_table(['实验', 'Welch N₀，ADC²/Hz', 'N₀×20 MHz 初始功率，ADC²', '复高斯仿真超限率'], noise_rows)}

实际运行的最终门限来自固定 PB 迭代：以 `N₀×Fs` 初始化，令 q = −ln(Pfa)，连续 30 次计算 `mean(P | P < qσ²) / [1−q/(exp(q)−1)]`，补偿 H0 噪声被截断的能量。**运行值采用上表的迭代 H0 功率，并非直接采用 Welch 初始功率。** 仿真超限率来自每组 200 万个复高斯样点，验证名义模型；真实 IF 的超限率包含干扰脉冲，不能用它代替无脉冲虚警率。

### 3.2 频谱与单侧陷波器

在 1170 MHz ±1 MHz 内找峰，以距中心 1.2–1.8 MHz 两侧频点估计局部噪声底。PSD 经 21 点平滑后，选择包含峰值且高于噪声底 3 dB 的连续主谱段；扣除噪声底后取累积能量 0.5%–99.5% 边界。陷波中心取边界中点，全宽取“边界宽度 +100 kHz”，向上取整到 50 kHz。这里的 99% 针对选定主谱段的超额能量。

02、04 的主谱段约 374–376 kHz，得到 500 kHz 全宽。05 的主谱段约 1011 kHz，得到 1150 kHz 全宽；其原 800 kHz 深阻带不能完整覆盖这段谱。新中心相对 1170 MHz 分别偏移约 −0.195、−0.391、+9.375 kHz，所以谱配置比较同时包含中心与宽度变化。

![05 原始 IQ Welch 频谱与新陷波边界](spectrum_05.png)

图中橙色点为噪声参考频点，水平虚线为其 PSD 均值，红色竖虚线为新深阻带边界。另见[02 频谱](spectrum_02.png)、[04 频谱](spectrum_04.png)。

沿用 `TFBlankerV1` 的复数单侧 FIR：513 抽头，每侧频域过渡 150 kHz，Kaiser β = 5.65326，脉冲尾部裕量 2 μs。02、04、05 的 IQ 陷波中心分别为约 −6.450195、−5.400391、−5.390625 MHz。新 500 kHz 和 1150 kHz 滤波器深阻带最差响应分别约 −56.77、−59.95 dB，镜像侧中心响应接近 0 dB；未使用正负频率对称的双侧陷波。

## 4. 八种配置相对 PB 的效果

表中单位均为 dB-Hz，正值表示优于同一时刻的原 PB。

{md_table(['配置', '02 B2a', '02 Pilot', '04 B2a', '04 Pilot', '05 B2a', '05 Pilot'], summary_rows)}

![八种配置的配对载噪比变化](analysis/overall_cno.png)

02 组各 TF 配置均有收益，B2a 约 +0.27～+0.28 dB-Hz，谱带宽候选之间接近。04 组原 TF 分数最高，为 +0.2361 / +0.2134 dB-Hz；H0 谱带宽候选约 +0.22 / +0.19 dB-Hz。05 组原 TF 为 −1.7110 / −1.6417 dB-Hz；新谱带宽候选改善到 B2a 约 −1.38 dB-Hz，仍整体低于 PB。

### 4.1 逐星结果

下表新 TF 统一展示 H0、实测谱参数、1 μs。PB 绝对 C/N₀ 为共同窗口内的时间中位数，Δ 为同一时刻差值的中位数。

{md_table(['实验', 'PRN', '共同窗数', 'PB B2a，dB-Hz', '原 TF ΔB2a', '新 TF 1 μs ΔB2a', '新 TF 1 μs ΔPilot'], star_rows)}

05 组新 TF 对三颗星的 B2a 差值均为负，范围 −1.512～−1.178 dB-Hz，PB 优势不只来自一颗星。02、04 的三颗星则全部为正。完整八配置逐星数据见[共同窗口比较表](paired_cno.md)。

## 5. 分离门限、谱配置和时间窗的作用

### 5.1 直接配对变化

每个单元格依次为 **B2a / Pilot**，单位 dB-Hz。前两行保持其余参数不变；第二行的谱中心与带宽一起变化。

{md_table(['参数改动', '02', '04', '05'], contrast_rows)}

降低 H0 门限带来小幅载噪比下降，三个实验的逐星 B2a 直接差值均为负。谱配置调整后，三组逐星 B2a 直接差值均为正；05 的 PRN 27、38、41 分别提升约 0.341、0.334、0.305 dB-Hz，形成一致的改善。04 的 Pilot 直接变化为 −0.0034 dB-Hz，缩窄到 500 kHz 没有形成明确的双指标优势。

新谱配置 1 μs 相对原 TF 的直接净变化为：02 +0.0028、04 −0.0200、05 +0.2824 dB-Hz（B2a）。这与第四节分数直接相减得到的数值不同，原因是中位数汇总口径，分析参数效应时采用本节的同时间直接差值。

### 5.2 门限下降后的作用覆盖

下表为完整 20 秒的前端统计，先按每条跟踪实际 RF 样点数加权，再取三颗星中位数；单位为百分比。

{md_table(['实验', '原门限超限比例', 'H0 超限比例', '原 TF 平均权重', 'H0 3 μs 平均权重', 'H0 1 μs 平均权重', 'H0 5 μs 平均权重'], duty_rows)}

原 TF 和 H0 TF 使用相同 3 μs 窗时，超限比例只增加约 0.40–0.54 个百分点，平均权重却升至原来的约八至九倍。这来自幅度检测之后的掩码扩展与平滑，超限样点比例不能直接当作最终作用覆盖率。

前端实际输出为 `z = x − w × (h_bandpass * x)`，平均权重表示对干扰带分量的加权扣除强度。**平均权重 45% 不表示将 45% 的全带 IQ 样点置零**；PB 的消隐比例和 TF 的平均权重具有不同物理含义。

本滤波器半长 D/Fs = 12.8 μs，尾部裕量 P/Fs = 2 μs；扩展半径 `A=D+P+K`，三角核过渡跨度为 `2K/Fs`。单个孤立超限点的满权重平台约 29.6 μs，1–5 μs 设置对应约 31.6–39.6 μs 的非零作用支持。因此，1 μs 并不等于只处理 1 μs 的 IQ。

20 MHz、每复样点 Pfa = 10⁻³ 的 H0 模型对应每秒期望约 2 万个噪声超限样点；有限长度 FIR 的时间扩展会将这些触发覆盖到邻域。实测权重增加符合这一机制，但本轮没有将真实 IF 的每个触发标成噪声或 DME，不能把全部增加量归给噪声虚警。

### 5.3 1–5 μs 边缘窗

以下保持门限、实测中心和带宽固定，直接对同一时刻的 **3 μs** 配置做差。每格为 B2a / Pilot，单位 dB-Hz。

{md_table(['边缘跨度 μs', '02', '04', '05'], edge_rows)}

![时间窗相对 3 微秒的直接配对变化](analysis/edge_direct_effects.png)

这些变化为 10⁻⁴～10⁻³ dB-Hz 量级。05 组 1 μs 相对 3 μs 提升约 0.00229 / 0.00278 dB-Hz，5 μs 则下降约 0.00210 / 0.00189 dB-Hz。三个实验将 1 μs 延长到 5 μs，平均权重增加约 3.6–3.7 个百分点，载噪比没有对应收益。

相对 PB 的汇总分数中，02/4 μs 的 B2a 最高，05/5 μs 的 Pilot 最高；直接与 3 μs 配对时，并没有相应优势。这个排序变化也说明，不能据千分之几 dB-Hz 的分数差确定通用最优窗。本轮按“减小作用覆盖，同时保持载噪比”的原则选择 **1 μs**。

## 6. 05 组有效窗口退化

05/PRN 27 的原 PB 有 75 个有效窗口，七种 TF 都只有 72 个。共同缺失的端点约为源文件 **18.200007、18.400007、20.000008 秒**，对应的 400 ms 支持内均为 LONG，且没有样点间断；排除原因是 Pilot C/N₀ 为 −∞。在新谱带宽 TF 中，这三个端点的 B2a C/N₀ 也为 −∞。

接收机 VSM 使用 `mean(power)² − var(power)` 的矩判据。当线性载噪比估计为零时，转为 dB 得到 −∞；相邻两次 0.5 平均会将其带到相邻存储窗口。这里记录的是估计值退化，跟踪状态机未进入重捕。原 TF 在前两个异常端点还给出约 28.50、28.39 dB-Hz 的有限 B2a 值，但 Pilot 同样为 −∞。

因此，**零重捕不代表所有载噪比窗口都正常**。正式相对 PB 比较对所有配置统一使用剩余 72 个共同窗口，异常窗口单独保留在[排除明细](analysis/excluded_windows.md)。05 组 PB 在有限窗口载噪比和有效窗口数量上都优于本轮 TF。

05 组约 1.0 MHz 的主谱段支持拓宽陷波，且实测获得了约 0.33 dB-Hz 改善；新 TF 仍有约 1.38 dB-Hz 的 PB 差距。当前结果已明确：只调整 1–5 μs 不能补齐这个差距。差距中残余带外干扰、时域作用覆盖、信号谱损失和 VSM 对处理后幅度统计的响应各占多少，**？** 本轮未对这些因素分别试验。

## 7. 参数选择与下一步

| 实验 | 谱约束 TF 继续试验的配置 | 本轮判断 |
| --- | --- | --- |
| 02 | H0 门限 31.4839 ADC；RF 中心 1169.999805 MHz；500 kHz 全宽；1 μs | 相对 PB 约 +0.281 dB-Hz，与原 TF 接近；4 μs 仅有极小的汇总分数优势。 |
| 04 | H0 门限 773.8196 ADC；RF 中心 1169.999609 MHz；500 kHz 全宽；1 μs | 相对 PB 约 +0.227 dB-Hz；原 TF 分数更高，H0 条件下 500/800 kHz 的差别很小。 |
| 05 | H0 门限 761.8753 ADC；RF 中心 1170.009375 MHz；1150 kHz 全宽；1 μs | 谱带宽应加宽；新 TF 相对 PB 仍约 −1.381 dB-Hz，本轮以 PB 作为效果较好的基准。 |

下一轮优先处理 05：固定 H0 门限与 1 μs，围绕 1150 kHz 对频域带宽继续分档，同时记录处理后干扰残余谱与前端作用权重。对 18–20 秒出现的 VSM 退化窗口保留相关器功率矩，确认其与处理后幅度变化的关系。02、04 可用上述 500 kHz / 1 μs 配置扩展到更长片段验证，当前无需继续细扫 1–5 μs。

本轮完成结果分析与报告，未启动新的接收机计算。

## 8. 程序入口、图与原始证据

| 内容 | 文件 |
| --- | --- |
| 频谱、噪声功率、冻结门限与带宽 | [tf_h0_prepare.m](programs/tf_h0_prepare.m) |
| PB 与全部 TF 的共同跟踪入口 | [tf_h0_run.m](programs/tf_h0_run.m)，`v=1` 为 PB，`v=2:8` 为 TF |
| 本报告数值复核、直接配对及绘图 | [tf_h0_analyze.m](programs/tf_h0_analyze.m) |
| 本报告生成程序 | [write_analysis_report.py](programs/write_analysis_report.py) |
| 八配置载噪比统计 | [cno_summary.md](cno_summary.md)、[paired_cno.md](paired_cno.md) |
| 参数直接配对统计 | [总体](analysis/direct_effects.md)、[逐星](analysis/direct_effects_per_satellite.md) |
| 前端检测、平均权重与非零覆盖率 | [sample_weighted_duty.md](analysis/sample_weighted_duty.md) |
| 72 条原始记录复核 | [independent_audit.md](analysis/independent_audit.md) |
| 频谱与门限数值 | [spectral_estimates.md](spectral_estimates.md) |
| 数值数组 | [comparison.mat](comparison.mat)、[analysis.mat](analysis/analysis.mat) |
| 跟踪时间序列图 | [02](cno_timeseries_02.png)、[04](cno_timeseries_04.png)、[05](cno_timeseries_05.png) |
| 图索引 | [图片索引.md](analysis/图片索引.md) |
| 运行与复核日志 | [run_console.md](run_console.md)、[analysis_console.md](analysis_console.md) |
| 完成记录 | [completion.md](completion.md) |

跟踪结果位于各 `实验号_配置名/temp/Trk_Prn_XX_final.mat`，对应配置保存为该目录下的 `settings.mat`。本轮报告只使用本次 20 秒短测，不混用旧完整实验的 TF 数值。接收机源码保持原样，分析程序放在外部 `batch/data1020_tf_h0`，本次新增分析和报告均无 GUI 执行。
'''

target = ROOT / '参数效果分析报告.md'
target.write_text(report, encoding='utf-8')
figure_rows = [
    ['总体效果', '[overall_cno.png](overall_cno.png)', '八配置相对 PB 的配对载噪比变化'],
    ['边缘窗', '[edge_direct_effects.png](edge_direct_effects.png)', '1–5 μs 相对 3 μs 的直接配对变化'],
]
for i in ids:
    figure_rows.extend([[f'{i:02d} 频谱', f'[spectrum_{i:02d}.png](../spectrum_{i:02d}.png)', '原始 IQ Welch PSD、噪声参考频点与陷波边界'],
                        [f'{i:02d} 载噪比', f'[cno_timeseries_{i:02d}.png](../cno_timeseries_{i:02d}.png)', 'PRN 27/38/41 的有效窗口时间序列']])
(ROOT / 'analysis/图片索引.md').write_text('# 参数效果分析图片索引\n\n' + md_table(['内容', '图片', '说明'], figure_rows) + '\n', encoding='utf-8')
for name in ['tf_h0_analyze.m', 'write_analysis_report.py']:
    shutil.copy2(REPO / 'batch/data1020_tf_h0' / name, ROOT / 'programs' / name)

for path in [target, ROOT / 'analysis/图片索引.md']:
    for ref in re.findall(r'\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
        assert (path.parent / ref).exists(), ref
print(f'Report: {target}')
print(f'Characters: {len(report)}; raw tracks: {len(audit)}; excluded records: {len(excluded)}; verified core hashes: {len(hash_rows)}')
