# 可独立使用的 LLM 软件接收机升级 Prompt

版本：R3，2026-09-30。用途：用户将下文交给 LLM 并明确要求开始实施时，用于指导下一阶段开发。生成或审阅本文件本身不授权修改程序。以下指令自包含；同目录三份报告和延迟验证简报提供更完整的推导与证据。

---

你需要在 F:/matlab-GNSSsdr/BDS/B2a 为 BDS B2a 软件接收机实现独立的 TF_Blanker_v1 前端，并完成四组半物理带干扰 RF 的单星带宽比较。请读完约束再修改。先核对工作树、已有实现和项目指令，保留用户已有修改，记录源码与配置快照。不要把上轮原型脚本已运行当作生产接收机已实现。

## A. 已经确定的要求

1. 主实验只实现 v1：固定中心 -450000 Hz，固定深阻带总宽 400000 Hz，另比较 600000 Hz。400 MHz 是已经纠正的笔误，不再询问单位。
2. 使用复 IQ 线性相位 FIR，Kaiser β=5.65326、每侧过渡带 150000 Hz。输入为 int8/int16 双路交织 IQ，fs 从原配置继承，支持 25 MHz、30.69 MHz 等合法采样率，不能写死 25 MHz。未显式配置抽头时按 25 MHz/641 抽头换算：D=max(1,ceil(320*fs/25e6))、L=2D+1；显式合法奇数抽头优先。默认 25 MHz 为 641，30.69 MHz 为 787。对应频点网格最差阻带约 -59.2/-59.7 dB，不宣称严格 60 dB；新 fs/显式长度重新测频响。
3. 时域直接比较幅度：m[n]=1 当 abs(rawIQ[n])>=T_A，否则为 0。阈值继承该数据集的 PB_settings.Th_static_tracking，缺失时用 Th_static；显式 TF 幅度覆盖优先。四个 int16 DME 组约 192.7391788329，无 DME 组约 1288.1605785013，不能将这些数字全局套给 int8。读入浮点后保持 ADC 数值，不归一化，不按位宽或 fs 重复缩放门限；当前 30.69 MHz/int8 默认跟踪门限约 53.64。幅度比较是规范判决；平方形式在精确算术下等价，浮点边界不保证逐位相同。如采用平方优化，先转浮点并针对目标输入格式验证。
4. 采用扩展平台与单位和三角软边缘，12 μs 三角核跨度、2 μs 尾部裕量作为首轮候选。检测在原始 IF 上执行。
5. PB 与 TF 是同一前端位置的互斥模式，绝不默认串联。处理后 IF 再进入现有捕获、相关器和跟踪；S4、C/N0 仍由处理后相关量计算。
6. 不要求实时性。性能和可验证性优先，先做简单可靠的离线分块实现，不先写 GPU/MEX 或共享内存调度服务。
7. v2 仅作后续研究，不实现中心自适应、带宽自适应或梯度 ANF。IIR 不在本次实现范围。
8. 不为提高表面指标调整 PLL/DLL/FLL/KF、检测门限、S4 公式或原始文件时间位置。新增有效性传播是允许且必要的。

## B. 必读上下文

- docs/tf_blanker_design/revision_20260930/01_方案评估报告.md
- docs/tf_blanker_design/revision_20260930/02_代码改写计划.md
- docs/tf_blanker_design/revision_20260930/03_算法设计报告.md
- docs/tf_blanker_design/revision_20260930/05_IQ格式与延迟对齐验证简报.md
- docs/semiphysical_recompute/五组半物理输入SDR重算运行方法.md
- docs/semiphysical_recompute/five_cases.json 和 configs 内原始五份 JSON
- 当前 setupPaths、配置入口、捕获、trackOneChannel、REACQ、TrackResults2 和相关测试
- results/tf_blanker_design/review_20260930/design_review.json、contract_verification.json 及独立设计脚本
- results/tf_blanker_design/iq_alignment_20260930/verify_iq_fir_alignment.m、alignment_verification.json

若报告与本 prompt 有算法细节冲突，以用户最新批复与算法报告的严格样本定义为准并说明差异。旧目录的 frontend_design_proposal.json 含旧版“单位待确认”等历史字段，不直接用作生产契约。results/tf_blanker_design 下包括历史短段和 R2 设计验证，均不是新的真实单星跟踪结果。R2 对两个带宽验证了 H=670 的分块参考，并以一个样本错位、无 halo 为负对照；这些通过记录不能替代生产实现的测试。

## C. 必须遵守的数学定义

数学索引 n 为整个原始 IQ 文件内从 0 开始的复样本编号。MATLAB 数组位置另行转换。fileType=2，存储 I0,Q0,I1,Q1,…，复数为 I+jQ。int8 每复样本 2 字节，int16 为 4 字节；字节位置为 n*bytesPerComplexSample，不得固定乘 4。int16 字节序沿用源数据设置，当前 Windows 和实验文件为小端。拒绝不完整 IQ 偏移和破损尾部；不把实数单路交给 TF。

先解析有效抽头 L，再令 D=(L-1)/2；默认 25/30.69 MHz 分别为 D=320/393。设计实对称低通 l[u]，u=0,…,2D，名义截止频率为 stopbandWidthHz/2+transitionEachSideHz/2。定义：

~~~text
omega_c = 2*pi*centerHz/fs
b[u] = l[u] * exp(1j*omega_c*(u-D))
h[u] = delta[u-D] - b[u]
q[r] = sum_{u=0..2D} b[u]*x[r-u]
yNF[n] = x[n] - q[n+D]
~~~

指数必须是 u-D。不要把复数单侧陷波替换为实系数 ±fc 双侧陷波。

令 K=round(12e-6*fs/2)，P=round(2e-6*fs)。25 MHz 为 K=150、P=50；30.69 MHz 为 K=184、P=61。保存取整后实际时长。定义：

~~~text
g[k] = max(K-abs(k),0)/K^2, k=-K..K
A = D + P + K
md[n] = max(m[n-r], r=-A..A)
w[n] = sum(g[k]*md[n-k], k=-K..K)
z[n] = x[n] - w[n]*q[n+D]
~~~

g 有 2K+1 点，名义端点跨度为 12 μs、实际为 2K/fs，sum(g)=1。25/30.69 MHz 分别为 301/369 点。检测集合扩展 D+P 后必须 w=1；0<=w<=1。不得仅用 conv(m,g) 替代扩展平台，也不得将重叠脉冲权重相加。

最终表达式等价于 (1-w)*x+w*yNF，必须用独立的双支路参考验证。只在 w>0 的有效位置进行滤波扣除，w=0 位置直接复制原始数据。禁止先给 x 乘 w 再滤波，因为权重与滤波不交换。

## D. 样本对齐和边界：最高优先级正确性要求

保守 halo 半径 H=D+P+2K。25 MHz 默认 H=670（26.8 μs），30.69 MHz 默认 H=822（约 26.784 μs）。显式抽头改变时重新推导 H。它是充分前后文预算，不是要加进 GNSS 时间戳的钟差。

输出 [a,b] 时读取真实原始数据 [a-H,b+H]，在扩展区计算掩码、权重和线性卷积，只返回核心 [a,b]。绝对 n 对应局部 MATLAB 位置 p 时，使用因果 q 的 p+D 位置。不得用无补零等长 FFT 做循环卷积，不得每个跟踪毫秒重置缺乏历史的 FIR。

实现 readRange(startAbs,count)、read(count)、seekAbs(startAbs)、tellLogical()。source 的底层 ftell 可以超前或回退，但 outputStartAbs 必须始终等于实际物理样本起点。跟踪 absoluteSample 从逻辑游标或返回元数据获取。

捕获数组若实际始于 acqInputStartAbs，则从 1 开始的相对 codePhase 映射为 acqInputStartAbs+codePhase-1。当前已有 codePhaseAbs 不一定是文件绝对编号，先审查语义，不能按名字直接使用。加入新字段时更新通道模板和字段合并，防止多星/REACQ 丢失。

禁止把 D 或 H 样本补偿再加进 startOffset、TOW 或伪距。固定延迟已通过对齐消除，剩余相关峰畸变另作性能测量。

请求块边缘必须有真实 halo；物理文件起止外没有真实样本，不能将补零/镜像当有效数据。核心位于文件内而 halo 不足时，固定长度返回可保留 raw 并标记 valid=false、boundaryBypass；相关监测不能使用它们。核心本身超过物理文件范围时按 EOF 短读/终止，不制造原始样本。捕获选择有效连续段并记录真实起点，必要时增加读取长度。文件中部的实验起点可以向前读取真实 halo，不当成文件边缘。

v1 是固定有限邻域运算。各卫星使用私有读取器是允许的，只要同一绝对样本的阈值、系数和上下文一致。无需为了“共享前端”先建中央服务。seek 后按绝对范围重新算即可；REACQ 处理缓存不能再次经过 TF，回退使用逻辑索引而非预读后的物理 fseek。

## E. 代码组织与兼容性

建议新增 frontend/TFBlankerV1.m、frontend/IFSource.m、一个选择工厂和小型系数函数，并把目录加入 setupPaths。名字可按仓库惯例调整，职责必须保持。

配置增加 Frontend.mode=off/pb/tf_v1。缺失时按原 EnablePB 映射；显式 mode 为唯一选择。tf_v2 若保留枚举，调用时明确报未实现，不能静默替代。

TF 设置至少包含 centerHz、stopbandWidthHz、transitionEachSideHz、firTaps/null、referenceTaps=641、referenceSamplingFreqHz=25000000、kaiserBeta、thresholdAmplitude/null、thresholdSource、triangleSpanUs、pulseTailMarginUs、boundaryPolicy。firTaps=null/缺失时按参考换算；显式合法奇数优先，保存最终有效抽头和 D/K/P/H。校验数值有限、幅度阈值正、频带完整落在 Nyquist 区间；TF 只接受 fileType=2 的 int8/int16，其他格式明确拒绝。旧 off/pb 能力保持。

修改 runFromJsonConfig 的白名单/嵌套合并与生效配置保存。接入 runAcquisition、trackOneChannel 的普通和 REACQ 两条读取路径、runProbeIf，以及其他正式入口 run_B2a/runFromSettings。保留 off/pb 原有数值行为，不双重滤波。

只在跟踪模块增加 IF 获取、时间映射、有效性及统计传递，不将滤波方程、检测器或自适应逻辑写入 PLL/DLL 循环。核心和读取器不得依赖卫星 PRN。原始 RF、旧结果和五份原 JSON 不覆盖；新实验使用副本与新目录。

## F. 监测与保存

TF 之后的 IF 进入现有相关器，由 pilot Prompt 生成强度和 S4。保存每个实际积分核心区间的 detectorDuty、meanWeight、meanWeightSquared、weightSupportFraction、validCount、boundaryFlag、逻辑起止，以及配置/系数哈希。

这些统计不计重复 halo，不统一塞进 PB 的 PDC。保留 pilot 与 total C/N0 的区别。前端无效数据传播至积分和监测窗，不填零伪装有效强度；保持原有预热与去趋势规则。

不要新增未经验证的按权重除法、经验幅度补偿或 S4 降噪公式。S4 降低不自动代表改善，C/N0 估计增大也需结合跟踪稳定性和前端失真解释。

## G. 验证顺序与实验

先完成有意义的数值和时序测试：

1. 幅度门限及 >= 边界、目标格式下平方优化的可选验证、平台完整覆盖、单位和与权重范围。
2. 正负中心符号、冲激对齐、双支路/扣除表达式一致、w=0 恒等。
3. 随机分块、1 样本块、脉冲跨界、任意 seek 与长段参考等价。
   覆盖 int8/int16 × 25/30.69 MHz × 400/600 kHz，检查 2/4 字节换算、自动抽头与显式覆盖；其他 fs 也由配置计算，不能硬编码毫秒样本数。
4. 非零 skip、捕获非零起点、真实文件边缘、EOF 与 REACQ 交接样本映射正确。
5. 旧 off/pb 行为回归、配置实际生效、结果序列化不丢字段。
6. 相关峰、DLL S 曲线与载波相位检查，不能用数据对齐测试代替相关保真度。

根据数值类型和输入尺度设置误差容差。w=0 复制可要求逐值恒等，卷积实现之间使用说明清楚的相对/绝对容差。

已有实验室最大相对分块误差约 2.14e-16，采用的是按输入峰值归一化、1e-12 容差。这不是所有数据类型的固定误差保证。必须确保故意错开一个样本、去掉 halo 的版本不能通过；还需新增真实文件读取、配置生效、捕获/REACQ 交接测试。内存参考函数不直接充当生产读取器。

R3 另用生成的二进制 IQ 文件完成八种组合，最大相对误差 2.58e-15；补偿后冲激峰偏移均为 0，字节偏移、反向读取、EOF、无 halo/错一个样本的负对照通过。该脚本已做实验室文件读取，但未接入生产配置/捕获/REACQ，仍需生产实现测试。不能据此宣称整个接收机支持任意 fs 或 S4 无偏。

之后对 five_cases.json 第 2–5 组进行单星实验，优先 PRN 11。配置副本设 numberOfChannels=1、acqSatelliteList=[11]、useParfor=false，关闭导航/NMEA/地图；保留原 fs、IF、经验阈值、采样起点、PLL/DLL/FLL/KF、1 ms 积分、200 ms C/N0、60 s S4 窗、5 s 更新、0.1 Hz 去趋势及当前 150 s 预热。

先短段通过，再完成 715000 ms 全长的 PB、TF400、TF600，建议附 off 对照。每种模式用本模式前端捕获并跟踪；共同初始化回放如需要，单独作为受控实验。PRN 不可用时如实记录失败，不为不同方法分别挑选更好的卫星。单星不能要求有多星 PVT 解数。

任务串行启动并检查已有任务，记录失败和已完成配置，避免重复提交。每次输出新目录，保存实际参数和 MATLAB/源码版本。只有执行成功且结果完整性检查通过才标记完成。

## H. 400/600 kHz 决策与最终交付

已有 64 次合成数据配对比较：1350/2700 对每秒各配峰值/门限比 4/20，每种条件 16 个种子、每次 80 ms。强脉冲下 600 kHz 的理想码相关代理指标平均增加约 0.14 dB；较弱条件差值区间包含零；600 的有用分量强度 CV 均更大。这些幅度比没有标定为实测 -50/-60 dBm，代理指标不是跟踪 C/N0 或 60 s S4。因此继续比较 400/600，不预设 600 必然获胜。

以相同物理文件时间对齐，先报告每种方法的有效覆盖，再报告公共有效交集的 pilot C/N0 配对差、total 辅助指标、锁定/REACQ、码与相位内部稳定性、Prompt 强度、S4 和前端占比。

不能把高度重叠的 60 s S4 窗当作独立样本；用按连续时间分块的配对统计，块长至少覆盖监测窗并检查更长相关性。没有真值时不称绝对码误差，不把另一录制文件的无 DME 曲线直接当成逐点 S4 真值。

600 kHz 只有在跟踪收益稳定且没有引入失效或已知真值监测退化时才升为主候选。差异无法与统计不确定性区分时保留较窄的 400 kHz。若不同场景有取舍，逐组说明，不把 v1 改为在线带宽自适应。缺少 S4 真值时明确区分“跟踪更优候选”和“监测无偏已验证”。

最终交付：修改清单与原因、实际生效配置、数学/时序/回归结果、四组单星结果路径和比较报告、400/600 的证据结论、未验证事项。及时汇报进度与发现；不要将原型成功、较低 IF 功率或较低 S4 代替接收机级验证。

完成 v1 后停止扩展。v2、IIR 和新的 S4 校准属于后续独立任务。
