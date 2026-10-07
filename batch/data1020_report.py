"""Build an offline HTML index and inspect the DATA1020 experiment outputs."""
from __future__ import annotations

import argparse
import csv
import html
import json
import re
import statistics
from pathlib import Path


def read_json(path: Path) -> dict | list:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def esc(value: object) -> str:
    return html.escape(str(value))


def nmea_stats(run: Path) -> dict:
    path = run / 'pvt.nmea'
    if not path.exists():
        return {}
    rows = [line.split(',') for line in path.read_text(encoding='utf-8-sig').splitlines()
            if line.startswith('$GBGGA,')]
    rows = [row for row in rows if len(row)>9 and row[6]!='0' and row[9]]
    heights = [float(row[9]) for row in rows]
    if not heights:
        return {}
    result={'finiteGgaEpochs': len(rows), 'medianHeightM': statistics.median(heights),
            'minimumHeightM': min(heights), 'maximumHeightM': max(heights),
            'absHeightOver10kmEpochs': sum(abs(h)>10000 for h in heights)}
    log=run/'matlab.log'
    if log.exists():
        match=re.search(r'plotNavPost: track N=(\d+) after removing (\d+)',
                        log.read_text(encoding='utf-8-sig',errors='replace'))
        if match:
            result['plottedTrajectoryPoints']=int(match[1])
            result['removedJumpPoints']=int(match[2])
    result.update(read_json(run/'navigation_plot_verification.json'))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    cases = read_json(root / "cases.json")
    if not cases:
        raise SystemExit("Calibration manifest is not available yet.")
    rows, sections, summary = [], [], []
    for number, case in enumerate(cases, 1):
        run = root / f"full_{number:02d}_{case['id']}"
        report = read_json(run / "report.json")
        val = read_json(run / "validation.json")
        progress = [read_json(p) for p in sorted(run.glob("tracking_progress_prn*.json"))]
        state = "done" if val.get("pipelineOk") else report.get("stage", "pending")
        if val and not val.get("pipelineOk"):
            state = "failed"
        log = run / "matlab.log"
        prn_count = 0
        if log.exists():
            lines = log.read_text(encoding="utf-8-sig", errors="replace").splitlines()
            prn_count = sum("acquisition failed" in line or "coarse acquired" in line for line in lines)
        info = {
            "index": number, "id": case["id"], "status": state,
            "requestedSeconds": case["requestedMs"] / 1000,
            "pbAmplitude": case["thresholdAmplitude"],
            "nAcquired": report.get("nAcquired"),
            "nFixes": report.get("navSummary", {}).get("nFixes"),
            "acquisitionPrnEvaluations": prn_count,
            "progress": progress, "validation": val, "nmeaQuality": nmea_stats(run),
        }
        summary.append(info)
        if args.status:
            steps = ",".join(f"{p.get('prn')}:{p.get('completedMs', 0)/1000:.1f}s/{p.get('status')}" for p in progress)
            print(f"{number:02d} {case['id']}: {state}; search={prn_count}; "
                  f"acquired={info['nAcquired']}; fixes={info['nFixes']}; tracks=[{steps}]")
            continue
        acquired = val.get("acquiredPrns", [])
        tracks = val.get("tracks", [])
        if isinstance(tracks, dict):
            tracks = [tracks]
        lengths = [t["recordedMs"] / 1000 for t in tracks]
        duration = f"{min(lengths):.3f}–{max(lengths):.3f}" if lengths else "—"
        full_length = sum(t["recordedMs"] >= case["requestedMs"] for t in tracks)
        reacq = sum(t["reacqEpisodes"] for t in tracks)
        cells = [f'<a href="#case{number}">{esc(case["id"])}</a>', esc(state),
                 f'{case["thresholdAmplitude"]:.4f}', esc(len(acquired) if val else "—"),
                 esc(full_length if val else "—"), duration,
                 esc(info["nFixes"] if val else "—"), esc(reacq if val else "—")]
        rows.append("<tr>" + "".join(f"<td>{c}</td>" for c in cells) + "</tr>")
        prefix = run.name
        links = []
        for name in ["ui_config.json", "effective_settings.json", "validation.json", "report.json",
                     "acquisition_summary.csv", "tracking_summary.csv", "pvt.nmea", "matlab.log"]:
            if (run / name).exists():
                links.append(f'<a href="{prefix}/{name}">{name}</a>')
        for path in run.glob("run_B2a_*.mat"):
            links.append(f'<a href="{prefix}/{path.name}">完整结果 MAT</a>')

        def gallery(pattern: str) -> str:
            items = []
            for path in sorted(run.glob(pattern)):
                url = path.relative_to(root).as_posix()
                items.append(f'<a href="{esc(url)}"><img loading="lazy" src="{esc(url)}" '
                             f'alt="{esc(path.name)}"><span>{esc(path.name)}</span></a>')
            return '<div class="gallery">' + "".join(items) + "</div>"

        quality=info['nmeaQuality']
        quality_text=''
        if quality:
            quality_text=(f'<p>原始 GGA 高程中位数 {quality["medianHeightM"]:.1f} m；'
                          f'范围 {quality["minimumHeightM"]:.1f} 至 {quality["maximumHeightM"]:.1f} m；'
                          f'绝对高程超过 10 km 的异常候选 {quality["absHeightOver10kmEpochs"]} 个。'
                          '原始解保留，轨迹绘图另使用接收机的 500 m/s 跳点过滤。'
                          f'绘图点数：{quality.get("plottedTrajectoryPoints","未记录")}。</p>')
        tail=root / f'tail_{number:02d}_{case["id"]}'
        tail_validation=read_json(tail / 'validation.json')
        tail_text=''
        if tail_validation:
            tail_text=(f'<p><strong>后段独立冷启动补跑：</strong>捕获 {tail_validation.get("nAcquired")} 颗星，'
                       f'有限定位历元 {tail_validation.get("nFixes")} 个。'
                       f'<a href="{tail.name}/validation.json">补跑核验</a> · '
                       f'<a href="{tail.name}/tracking_summary.csv">补跑跟踪统计</a> · '
                       f'<a href="{tail.name}/figures/navResult/enu_displacement.png">补跑导航图</a>。</p>')
        sections.append(f'<section id="case{number}"><h2>{number}. {esc(case["id"])}</h2>'
                        f'<p class="filename">{esc(case["file"])}</p>'
                        f'<p>IF：{case["IF"]/1e6:g} MHz；增益：{case["gain"]} dB；'
                        f'静态 PB：{case["thresholdAmplitude"]:.6f} ADC 幅度。'
                        f'<a href="probes/{case["id"]}.png">阈值与消隐率探测图</a> · '
                        f'<a href="probes/{case["id"]}.json">校准窗口数据</a></p>'
                        f'<p>状态：{esc(state)}；捕获 PRN：{esc(acquired)}；实际跟踪长度：{duration} s。</p>'
                        '<p class="links">' + " · ".join(links) + '</p>' + quality_text + tail_text
                        + gallery("figures/AcqResult/*.png") + gallery("figures/navResult/*.png")
                        + '<details><summary>逐星跟踪图</summary>'
                        + gallery("figures/trkResult/*.png") + '</details></section>')
    if args.status:
        return
    text = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>DATA1020 B2a 静态 PB 实验</title><style>
body{font:16px/1.65 system-ui,"Microsoft YaHei",sans-serif;max-width:1280px;margin:36px auto;padding:0 24px;color:#182333;background:#f7f9fc}
h1,h2{color:#12365c} table{border-collapse:collapse;width:100%;background:white}
th,td{border:1px solid #d7dfe9;padding:10px;text-align:left}th{background:#e9f0fa}
section{border-top:2px solid #d7dfe9;margin-top:38px;padding-top:12px}a{color:#145d9d}
.filename{overflow-wrap:anywhere;color:#526174}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(400px,1fr));gap:18px}
.gallery a{display:block;background:white;padding:8px}.gallery img{width:100%;height:auto}.gallery span{font-size:13px}
summary{cursor:pointer;margin:20px 0;font-weight:bold}.links{line-height:2.2}
</style><h1>DATA1020 B2a 静态 PB 实验</h1>
<p>2026-10-08 · MATLAB R2024b · 20 MHz、交织 int16 IQ · PRN 1–63 全搜索 · 最多 6 个进程 worker。</p>
<p>每份文件在全时段均匀抽取 21 个 10 ms 窗口，以本项目动态 PB 公式（Pfa=10⁻⁴）估计阈值，取中位数后固定。
捕获和跟踪采用同一静态 ADC 幅度阈值。两个 1175.4 MHz 文件采用数字 IF +1.05 MHz。
从文件开头处理，按接收机要求保留末尾 1 秒。导航历元间隔 0.5 秒；星历和位置仅来自本次跟踪。</p>
<p>经纬度轨迹图采用无底图的坐标网格，起终点及时间着色可直接离线查看。</p>
<p>串行与并行捕获的所有输出字段已在零 IF 和非零 IF 实测输入上逐字段核对。
<a href="parallel_acquisition_verification.json">一致性核验</a> · <a href="cases.json">文件与校准清单</a> ·
<a href="experiment_summary.csv">完整实验汇总 CSV</a> · <a href="full_summary.csv">运行耗时</a> ·
<a href="active_scheduling_verification.json">跟踪调度一致性</a> · <a href="source_hashes.json">源码指纹</a></p>
<p>“done”表示流水线返回成功。“全长记录”允许中途失锁及重捕获，不代表连续锁定。
实际跟踪覆盖、失锁重捕获和有限导航解分别报告；位置没有外部真值校验。</p>
<table><thead><tr><th>文件简称</th><th>状态</th><th>PB 幅度阈值</th><th>捕获星数</th>
<th>全长记录星数</th><th>各星实际记录秒数</th><th>有限定位历元</th><th>重捕获事件合计</th></tr></thead><tbody>'''
    diagnostics = '''<details><summary>调试与核验记录</summary>
<p>先对 HUR、103801 和 111407 各运行 5 秒、4 颗候选星的 smoke，随后进行全星全时段实验。
HUR 的 125–155 秒区间对比 1 ms 和 5 ms 相干积分，1 ms 未改善末段失锁；
beiqijiatai 弱 PRN 25 的 1 ms 复测也在 6.836 秒结束，因此正式实验保留原 5 ms 长相干设置。</p>
<p><a href="tail125_prn38_coh1/diagnostic.json">HUR 1 ms</a> ·
<a href="tail125_prn38_coh5/diagnostic.json">HUR 5 ms</a> ·
<a href="weak25_coh1/diagnostic.json">弱 PRN 25 复测</a> ·
<a href="figure_verification.json">最终绘图核验</a> ·
<a href="timeline_verification.csv">逐星采样时间轴核验</a> ·
<a href="offline_map_verification.json">离线轨迹图核验</a> ·
<a href="final_validation.json">最终输出核验</a></p></details>'''
    text += "".join(rows) + "</tbody></table>" + diagnostics + "".join(sections) + "</html>"
    (root / "index.html").write_text(text, encoding="utf-8")
    (root / "consolidated_report.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    flat=[]
    for item,case in zip(summary,cases):
        val=item['validation']; tracks=val.get('tracks',[])
        if isinstance(tracks,dict): tracks=[tracks]
        lengths=[t['recordedMs']/1000 for t in tracks]
        complete=[t['PRN'] for t in tracks if t['recordedMs']>=case['requestedMs']]
        early=[t['PRN'] for t in tracks if t['recordedMs']<case['requestedMs']]
        flat.append({'case':case['id'],'status':item['status'],
                     'inputSeconds':case['durationSeconds'],'requestedSeconds':case['requestedMs']/1000,
                     'IF_Hz':case['IF'],'gain_dB':case['gain'],'staticPB_ADC':case['thresholdAmplitude'],
                     'searchedPRNs':len(val.get('searchedPrns',[])),
                     'acquiredCount':val.get('nAcquired'),'acquiredPRNs':' '.join(map(str,val.get('acquiredPrns',[]))),
                     'fullLengthCount':len(complete),'fullLengthPRNs':' '.join(map(str,complete)),
                     'earlyEndedPRNs':' '.join(map(str,early)),
                     'recordedMinSeconds':min(lengths) if lengths else None,
                     'recordedMaxSeconds':max(lengths) if lengths else None,
                     'finiteNavigationEpochs':val.get('nFixes'),
                     'plottedTrajectoryPoints':item['nmeaQuality'].get('plottedTrajectoryPoints'),
                     'removedJumpPoints':item['nmeaQuality'].get('removedJumpPoints'),
                     'medianHeightM':item['nmeaQuality'].get('medianHeightM'),
                     'absHeightOver10kmEpochs':item['nmeaQuality'].get('absHeightOver10kmEpochs'),
                     'trackingPNGs':val.get('trackingPlotCount'),'navigationPNGs':val.get('navigationPlotCount')})
    with (root/'experiment_summary.csv').open('w',encoding='utf-8-sig',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(flat[0]))
        writer.writeheader(); writer.writerows(flat)
    print(root / "index.html")


if __name__ == "__main__":
    main()
