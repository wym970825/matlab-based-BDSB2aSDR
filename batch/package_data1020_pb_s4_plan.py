"""Prepare the PB 02/04/05 S4 plan and copy verified, immutable receiver products."""
import argparse
import csv
import hashlib
import html
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path('F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison')
PACKAGE = ROOT / 'pb_02_04_05_s4_plan'
S4 = Path('F:/matlab-GNSSsdr/BDS/S4repair_basedOnSDR-v2')
NAME = 'BDSB2a_DATA1020_PB_02_04_05_20261009'
DESTINATIONS = [Path('H:/SDR-result-backup') / NAME,
                Path('F:/matlab_project/dme_L5_Scintillation-v3/results/sdr_backups') / NAME]


def read_json(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))


def write_json(p, data):
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def digest(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def csv_rows(p):
    with p.open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def prepare():
    PACKAGE.mkdir(exist_ok=True)
    manifest = read_json(ROOT / 'manifest.json')
    entries = [e for e in manifest['entries'] if e['experimentNumber'] in (2, 4, 5)]
    metrics = csv_rows(ROOT / 'comparison/satellite_tracking_metrics.csv')
    intervals = csv_rows(ROOT / 'comparison/continuous_tracking_intervals.csv')
    selected = [r for r in metrics if r['mode'] == 'PB' and int(r['experimentNumber']) in (2, 4, 5)
                and float(r['longestNoReacqSeconds']) >= 180]
    assert len(selected) == 26
    records = []
    for e in entries:
        source = Path(e['pbDir'])
        tracks = [r for r in selected if int(r['experimentNumber']) == e['experimentNumber']]
        points = csv_rows(source / 'figures/navResult/satellite_track_points.csv')
        e['backupRelativeDirectory'] = source.name
        e['selectedPrns'] = [int(r['PRN']) for r in tracks]
        e['positionBoundsPB'] = {k: [min(float(p[k]) for p in points), max(float(p[k]) for p in points)]
                                 for k in ('latitudeDeg', 'longitudeDeg')}
        e['selectedTracks'] = [{k: r[k] for k in ('PRN', 'longestNoReacqSeconds', 'longestLongStateSeconds', 'reacqEpisodes')}
                               for r in tracks]
        e['qualifyingIntervals'] = [r for r in intervals if r['mode'] == 'PB'
            and int(r['experimentNumber']) == e['experimentNumber'] and r['criterion'] == 'no_reacq'
            and float(r['durationSeconds']) >= 180]
        # This package describes PB only. Retain common source identity/evidence, drop TF paths.
        e.pop('tfDir', None)
        e.pop('tfDigitalCenterHz', None)
        for f in sorted(source.rglob('*')):
            if f.is_file():
                records.append({'relativePath': f.relative_to(ROOT).as_posix(),
                                'bytes': f.stat().st_size, 'sha256': digest(f)})
        print(f'Inventoried PB {e["experimentNumber"]:02d}: {len(tracks)} selected satellites', flush=True)
    write_json(PACKAGE / 'receiver_files_sha256.json', records)
    write_json(PACKAGE / 'pb_selection_manifest.json', {
        'createdUtc': datetime.now(timezone.utc).isoformat(), 'status': 'plan_only_S4_not_run',
        'sourceRoot': str(ROOT), 'destinations': list(map(str, DESTINATIONS)),
        'selection': 'PB only; at least one continuous >=180 s state 1/2/3/4 interval without reacquisition; no elevation filter',
        'receiverFileCount': len(records), 'receiverBytes': sum(r['bytes'] for r in records),
        'selectedExperimentSatelliteCount': len(selected), 'entries': entries})
    plan = '''PB 02、04、05 真实数据 S4 修正执行计划（2026-10-09）
状态：计划已制定；本次未启动 S4 数值计算。

1. 范围与源结果
仅处理原编号 02、04、05 的 PB 结果，保留原编号及源文件身份；不重新捕获/跟踪、不读取大体积原始 IF 来重跑接收机。
02 / HUR_1：PRN 24、27、28、32、33、38、39、41，共 8 星。
04 / 103330：PRN 25、27、28、30、32、33、38、39、41，共 9 星。
05 / 103801：PRN 24、27、28、30、32、33、38、39、41，共 9 星。
合计 26 个实验—卫星组合，不限制仰角。
入选定义为至少存在一段连续 >=180 s、不重捕的跟踪区间（状态 1/2/3/4）；允许区间外重捕。05/PRN28 的合格段约183.573 s，保留其重捕前后独立弧段；05/PRN24 虽连续不重捕约199.003 s，但最长 LONG 只有113.003 s，仍入选，不能承诺每个UTC分钟均能产生有效所提结果。
入选是卫星级筛选。对入选星读取完整保存记录，在独立有效弧段内计算所有完整UTC分钟，并标记窗口是否落在>=180 s合格段内；不只截取最长180秒，也不把重捕前后的数据拼成一条连续弧。

2. 已核对的现有代码及需要新增的适配
说明文档：docs/真实场景实验入口说明_20261006.md。
旧入口 main_realSceneExperiment.m -> +s4repair/runRealScene.m -> +s4repair/runExperiment.m -> +s4repair/+s4/processAlignedTrack.m。
runRealScene 的 localDiscover 写死 I:/KLHP/IFData/230919110036.B.gns、优选旧目录以及 -8.45 MHz 默认频偏，不能仅替换 inputRoot 后直接运行。
拟新增 main_data1020PbS4.m、+s4repair/runData1020Pb.m、plot_data1020_pb_s4.m、verify_data1020_pb_s4.m（这些名称是计划，尚未创建）。新入口显式读取本计划 manifest，不扫描混入 TF，也不改动旧场景入口行为。
复用 configureFromResultDir、loadSettings、loadPositionAnchors、loadTrackChunks、processAlignedTrack；configureFromResultDir 会把 cfg.prns 设置成导航候选星，所以必须在其后覆盖为上述26组合，不能用导航入选或仰角再筛卫星。
检查 loadTrackChunks 对 *_001.mat 等分块和 *_final.mat 的选择：逐星与接收机最终记录数/样点末端核对；若分块不完整则在新适配层显式采用完整 final，避免有分块时漏读尾部，不重复拼接 final。

3. 参数与输入核验
三组采样率均为20 MHz、IF带宽20 MHz、int16复数I/Q；1 ms Prompt 及实际功率标度以 ui_results.mat:settings 为准，JSON为后备。读取实际Gain、usrp.scaleK、intTime、PB_settings.UseStatic、Th_static_tracking，禁止复制旧例的30.69 MHz、-105 dBm。
02：Fc=1176.45 MHz，怀柔候选台频率1170 MHz，deltaFrequencyHz=-6.45e6；静态PB幅度59.42393237630613。
04：Fc=1175.40 MHz，同一台频率1170 MHz，deltaFrequencyHz=-5.40e6；静态PB幅度1075.5673818815962。
05：Fc=1175.40 MHz，同一台频率1170 MHz，deltaFrequencyHz=-5.40e6；静态PB幅度1925.1040663670603。
台站归属沿用原FFT+空间接近匹配证据，不写成已解码确认身份。
门限dBm按 receiverCalibration：PwrK=scaleK+gain-10log10(Fs)，Th_dBm=20log10(Th_static_tracking)+PwrK。保存每组实际换算值、来源、单位，检查Ppre/Ppost/eta与门限一致性。
逐星预检 absoluteSample、Pilot_I_P、Pilot_Q_P、Ppre、Ppost、eta、PilotCNo、CNoInterval、trk_state/cur_state，检查有限值、维度、单调性、间断和有效覆盖。常规分支使用PilotCNo，不能替换为组合B2a C/N0。
残余SSC必须匹配PRN、pilot/data分支、Fs=20 MHz、频偏和响应资源版本；核查缓存键及频率覆盖，不误用25/30.69 MHz缓存。
receiverCalibration 的硬件验证条件目前只接受25 MHz及17.5/18 MHz带宽，本批20/20 MHz不满足。沿用 allowUnverifiedFrontendModel=true 生成明确标注的模型条件结果，保留 proposedModelValid 与 proposedValid 两套门控，不强制把硬件有效性置真。

4. UTC、弧段与三种S4定义
时间来自 pvt.nmea 的观测日期及导航样点锚点，调用 loadPositionAnchors -> mapSamplesToUtc；按实际Fs把absoluteSample映射UTC。检查settings中的BDT-UTC偏移，避免重复减4秒。禁止用2026处理目录日期，禁止把文件名本地时间直接当UTC。
日期为2022-10-20；首个定位UTC校验值：02为02:17:26.57Z，04为02:33:47.57Z，05为02:38:17.57Z。首个定位不是首个跟踪样点时刻，不能直接以其加相对样点秒数。
完整UTC自然分钟[HH:mm:00, HH:mm+1:00)为60 s窗口；绘图点置分钟中点，横轴显示HH:mm:ss UTC并标日期，保存起止UTC及源样点范围。约199秒记录通常只有2或3个完整UTC分钟，>=180秒连续跟踪不等于保证3个有效分钟。
沿用 requireStableTracking=true（状态3/4）、mc_aligned_iir；长弧二阶0.01 Hz butter+filtfilt，短弧沿用既有FIR。先核验 detrendIntensity 是否按非稳定状态/重捕/样点间隙正确切弧；必要时仅修复新适配的分段，不跨间断滤波。保留trendBranch和边缘效应信息。
S4_obs：同一原生Prompt强度去趋势后的std/mean；它是经过PB接收机处理的观测S4，并非未消隐原始IF的S4。
S4_conventional：使用保存的Pilot C/N0按分钟在线性Hz域平均，按现有常规噪声公式修正。
S4_proposed：静态PB门限联合拟合、残余SSC、经验矩修正，复用现有核心。
三方案用相同UTC窗及支持样本规则，主比较图/统计采用modelComparisonValid共同支持集；所有原始窗另表保留。失败为NaN且标原因；负根号截零记录标志，不把缺测画成0、不对失败窗插值。
保持原质量门槛（覆盖、Pilot C/N0覆盖/门限、锚点残差等），不为得到曲线放宽。05/PRN24即使全部所提窗无效，也应列出已尝试、失败原因及观测结果，而非从26组合清单消失。

5. 绘图来源与改造
用户所指 prop_truth/publication_figures/gps_solutions 的对应生产脚本为 plot_tf_reference_performance.m，由 main_compareAlignedDmeFree.m 调用。
其中 fig5_aligned_dme_free_s4 是四组曲线图，fig6_aligned_dme_free_accuracy 是依赖独立真值的RMSE/MAE/Bias柱状图。脚本写死四组注入实验标签和真值字段，需提取样式而非直接运行。
新plot_data1020_pb_s4复用174 mm宽、Arial 8 pt、观测灰色/常规蓝色/所提橘红色及线型；每实验按PRN分页（例如2x2面板），另导出每星三曲线与差值图。导出600 dpi PNG、矢量PDF/EPS/SVG和MATLAB FIG。所有时序图使用UTC，无相对时间横轴。
参考 +s4repair/+plot/exportRealScene.m 的质量诊断和缺测断线行为，补充PB占空比、Pilot C/N0、拟合残差、有效窗数和截零比例。
本批无独立闪烁真值，fig6类型改为“各星共同有效窗的三方案S4汇总/差值及有效窗数”柱状图，不能画成准确率或沿用真值RMSE/MAE/Bias标签；不同实验不强制对照。

6. 统一输出与地图/导航关联
计算主结果拟放在 S4repair_basedOnSDR-v2/results/data1020_pb_02_04_05_s4/（满足runExperiment输出必须在projectRoot内的现有限制）。
目录规划：index.html；provenance/{input_manifest,source_hashes,code_resource_hashes,verification}.json；tables/{all_windows,s4_three_method_comparison,common_windows,quality_counts,summary,navigation_window_links}.csv；tables/results.mat；experiments/{02-HUR_1,04-103330,05-103801}/publication_figures/gps_solutions/；receiver_context/。
表格主键experimentNumber+sourceId+PRN+windowStartUtc；保留合格弧ID、首末样点、源文件和PB源目录。跨实验同PRN按独立记录处理。
receiver_context复制三组现有卫星底图、导航图、pvt.nmea、satellite_track_points.csv及地图元数据。总首页每个实验卡片同时展示地图、定位UTC范围、导航图链接、26组合中的该组逐星S4图表；保存到备份后仍使用相对链接可打开。
navigation_window_links把每个S4窗的UTC起止与同组导航epoch关联，保存覆盖数量、经纬度范围/中位位置、DME距离及图件路径；依导航实际UTC匹配，禁止只按epochElapsedSeconds或PRN凑对应。没有导航覆盖的窗口如实标注。
现有B2a总index.html保持完整，在完成S4后增加02/04/05的S4入口链接；S4首页反向链接原接收机首页及本地receiver_context。完整新结果再同步到两个备份包的s4_results子目录，更新哈希及首页。

7. 无GUI执行与检查点
阶段A：只读输入预检；核对26组合、完整记录、PB参数、UTC锚点、SSC缓存和源哈希，输出input_validation。
阶段B：串行smoke 02/PRN27、04/PRN27、05/PRN24和PRN28，各取可用的1至2个UTC分钟；重点核对频偏、幅度标度、重捕切弧和短弧路径。若无共同有效窗，保留原因，不以此擅自删星。
阶段C：MATLAB -batch -singleCompThread，defaultFigureVisible=off，不开parpool；一次仅加载一颗星，逐星写MAT/CSV和完成标记后释放内存。断点恢复依据输入/代码/配置哈希，仅跳过已校验完成的星。
阶段D：合并26组合、独立公式检查、UTC唯一性/单调性/样点残差检查、地图导航匹配；从保存MAT单独出图，不重复拟合。
阶段E：检查所有图件无裁切/图例遮挡/缺测连线，检查26组合都有成功或明确失败记录。用小型合成/边界测试验证20 MHz配置、final分块尾部、PRN名单覆盖、05/PRN28间断及UTC日界，不重跑无关接收机实验。
阶段F：写计算简报，报告每星总窗/共同有效窗、失败原因、截零比例、三方法差异及前端模型适用边界；完成后对输入哈希复核并备份新结果。

8. 本次备份约定
复制02、04、05完整PB目录（含所有原保存PRN、跟踪MAT、配置、PVT、捕获/跟踪/导航图），不是只备份26个入选星；TF和原始IF大文件不在本次结果备份范围。
附本计划、PB选星及合格段manifest、所有接收机文件SHA-256、独立PB导航首页。复制文件保持原字节，包括MAT/JSON内历史绝对路径；新相对路径首页和manifest用于定位副本，不改写原始科研记录。
两个目标是用户指定的H:/SDR-result-backup和F:/matlab_project/dme_L5_Scintillation-v3（后者放results/sdr_backups下）。只新建专用包，不镜像删除，不覆盖冲突内容；逐文件比较大小和SHA-256，并核验首页本地链接。
'''
    (PACKAGE / 'execution_plan.txt').write_text(plan, encoding='utf-8')
    style = '<meta charset="utf-8"><style>body{font:16px/1.65 Arial,sans-serif;max-width:1180px;margin:30px auto;padding:0 20px}table{border-collapse:collapse}td,th{border:1px solid #bbb;padding:8px}img{max-width:850px;width:100%}pre{white-space:pre-wrap}a{color:#245baa}</style>'
    (PACKAGE / 'execution_plan.html').write_text('<!doctype html><title>PB 02/04/05 S4执行计划</title>' + style + '<h1>PB 02、04、05 S4执行计划</h1><pre>' + html.escape(plan) + '</pre>', encoding='utf-8')
    body = ['<!doctype html><title>PB 02/04/05 结果及S4计划</title>', style,
            '<h1>PB 02、04、05：接收机结果与S4执行计划</h1>',
            '<p>S4状态：仅制定计划，尚未计算。完整PB结果备份；26个实验—卫星组合拟用于S4分析，不限制仰角。</p>',
            '<p><a href="execution_plan.html">详细执行计划</a> · <a href="pb_selection_manifest.json">参数及选星清单</a> · <a href="receiver_files_sha256.json">接收机文件SHA-256</a></p>']
    for e in entries:
        n = e['backupRelativeDirectory']
        body += [f'<h2>实验 {e["experimentNumber"]:02d} · {html.escape(e["sourceId"])} · PB</h2>',
                 f'<p>源目录：{html.escape(e["pbDir"])}<br>定位 UTC：{e["utcStart"]} — {e["utcEnd"]}<br>入选PRN：{e["selectedPrns"]}<br>PB轨迹经纬度范围：{html.escape(str(e["positionBoundsPB"]))}</p>',
                 f'<a href="{n}/figures/navResult/lla_satellite_dme.png"><img src="{n}/figures/navResult/lla_satellite_dme.png" alt="实验{e["experimentNumber"]} PB卫星底图和怀柔站"></a>',
                 '<p>' + ' · '.join(f'<a href="{n}/{p}">{label}</a>' for label,p in [
                     ('ENU位置','figures/navResult/enu_displacement.png'),('ENU速度','figures/navResult/enu_velocity.png'),
                     ('DOP','figures/navResult/dop.png'),('天空图','figures/navResult/sky_plot.png'),
                     ('导航PVT','pvt.nmea'),('运行配置','ui_config.json')]) + '</p>',
                 '<p>入选星跟踪图：' + ' · '.join(f'<a href="{n}/figures/trkResult/PRN_{p:02d}_tracking.png">PRN {p}</a>' for p in e['selectedPrns']) + '</p>']
    (PACKAGE / 'backup_index.html').write_text('\n'.join(body), encoding='utf-8')
    # Source-side index resolves receiver folders in its parent; backup index uses sibling folders.
    source_html = '\n'.join(body)
    for e in entries:
        n = e['backupRelativeDirectory']
        source_html = source_html.replace(f'="{n}/', f'="../{n}/')
    (PACKAGE / 'index.html').write_text(source_html, encoding='utf-8')
    print(json.dumps({'files': len(records), 'GiB': sum(r['bytes'] for r in records)/2**30, 'plan': str(PACKAGE / 'execution_plan.html')}, ensure_ascii=False), flush=True)


def backup():
    records = read_json(PACKAGE / 'receiver_files_sha256.json')
    extras = ['execution_plan.txt','execution_plan.html','pb_selection_manifest.json','receiver_files_sha256.json']
    status = []
    for dest in DESTINATIONS:
        dest.mkdir(parents=True, exist_ok=True)
        needed = sum(r['bytes'] for r in records if not (dest / r['relativePath']).exists())
        assert shutil.disk_usage(dest).free > needed + 100*1024**2, f'Insufficient free space: {dest}'
        verified = 0
        previous = None
        for r in records:
            rel = r['relativePath']
            src, dst = ROOT / rel, dest / rel
            group = Path(rel).parts[0]
            if group != previous:
                print(f'Copy and verify {dest}: {group}', flush=True)
                previous = group
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists():
                assert dst.stat().st_size == r['bytes'] and digest(dst) == r['sha256'], f'Conflict, not overwriting: {dst}'
            else:
                shutil.copy2(src, dst)
                assert dst.stat().st_size == r['bytes'] and digest(dst) == r['sha256'], f'Copy verification failed: {dst}'
            verified += 1
        for name in extras + ['backup_index.html']:
            dst = dest / ('index.html' if name == 'backup_index.html' else name)
            src = PACKAGE / name
            if dst.exists():
                assert digest(dst) == digest(src), f'Metadata conflict: {dst}'
            else:
                shutil.copy2(src, dst)
            assert digest(dst) == digest(src)
        import re
        links = re.findall(r'(?:href|src)="([^"]+)"', (dest / 'index.html').read_text(encoding='utf-8'))
        for link in links:
            assert (dest / html.unescape(link)).is_file(), f'Broken link: {link}'
        result = {'destination': str(dest), 'completedUtc': datetime.now(timezone.utc).isoformat(),
                  'receiverFilesVerified': verified, 'receiverBytes': sum(r['bytes'] for r in records),
                  'method': 'every receiver file: byte size and SHA-256 against source inventory',
                  'metadataFilesVerified': 5, 'indexLocalLinksVerified': len(links), 'status': 'passed'}
        write_json(dest / 'backup_verification.json', result)
        status.append(result)
        write_json(PACKAGE / 'backup_status.json', status)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    # Confirm original contents still match the recorded inventory after copying.
    for r in records:
        p = ROOT / r['relativePath']
        assert p.stat().st_size == r['bytes'] and digest(p) == r['sha256'], f'Source changed: {p}'
    write_json(PACKAGE / 'source_integrity_after_backup.json', {'status':'passed','filesVerified':len(records),
               'completedUtc':datetime.now(timezone.utc).isoformat()})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare','backup'])
    args = parser.parse_args()
    prepare() if args.action == 'prepare' else backup()
