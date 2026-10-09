"""Build a local, evidence-linked PB/TF experiment atlas and comparison brief.

The receiver and comparison outputs are read-only inputs. Pending experiments
remain explicitly pending; this script never infers completed TF results.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import html
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import statistics
from urllib.parse import quote, unquote, urlsplit


CSS = """
:root{--ink:#212537;--muted:#616779;--purple:#552767;--orange:#d17830;--line:#dddfe7;--paper:#fff;--bg:#f3f4f8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.65 system-ui,'Microsoft YaHei',sans-serif}
main{max-width:1560px;margin:auto;padding:28px}h1{font-size:30px;margin:0 0 8px}h2{font-size:23px;margin:28px 0 12px}h3{font-size:18px;margin:12px 0}
p{margin:10px 0}a{color:var(--purple);text-decoration:none}a:hover{text-decoration:underline}code{font:12px/1.6 ui-monospace,Consolas,monospace;overflow-wrap:anywhere}
.lead{max-width:1100px;color:var(--muted)}.card,section{background:var(--paper);border:1px solid var(--line);border-radius:12px;padding:20px;margin:18px 0}
.hero{border-top:6px solid var(--purple)}.links{display:flex;gap:8px 18px;flex-wrap:wrap}.links a{font-weight:600}.muted,small{color:var(--muted)}
.notice{background:#fff4e8;border-left:4px solid var(--orange);padding:12px 16px}.ok,.pending,.weak{display:inline-block;border-radius:20px;padding:1px 10px;font-size:12px;white-space:nowrap}.ok{background:#e5f2e8;color:#25613c}.pending{background:#ececf4;color:#555}.weak{background:#fff0d9;color:#8a5519}
.scroll{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:10px 9px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}th{background:#f1eef5;white-space:nowrap}td.num{font-variant-numeric:tabular-nums;white-space:nowrap}.nowrap{white-space:nowrap}
.pair,.gallery{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.gallery.three{grid-template-columns:repeat(3,minmax(0,1fr))}.picture{margin:0;background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden}.picture img{width:100%;height:auto;display:block}.picture figcaption{padding:9px 12px;color:var(--muted);font-size:13px}.placeholder{padding:35px;text-align:center;border:1px dashed var(--line);color:var(--muted);min-height:160px}
details{border-top:1px solid var(--line);margin-top:16px;padding-top:10px}summary{cursor:pointer;font-weight:600}.kv{display:grid;grid-template-columns:1fr 1fr;gap:12px}.kv>div{background:#f7f7fa;padding:10px 13px;border-radius:6px}.statline{font-size:14px}.prns{font:13px/1.7 Consolas,monospace}.compact td{padding:7px 9px}.topnav{position:sticky;top:0;background:rgba(243,244,248,.96);padding:9px 0;z-index:3;display:flex;gap:18px;flex-wrap:wrap;border-bottom:1px solid var(--line)}
@media(max-width:900px){main{padding:14px}.pair,.gallery,.gallery.three,.kv{grid-template-columns:1fr}h1{font-size:24px}.topnav{position:static}}
@media print{body{background:white}main{max-width:none;padding:0}section,.card{break-inside:avoid}details{display:none}.topnav{position:static}a{color:inherit}.scroll{overflow:visible}table{font-size:10px}}
"""


def read_json(path: Path) -> dict | list:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def read_csv(path: Path) -> list[dict]:
    try:
        with path.open(encoding="utf-8-sig", newline="") as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []


def rows(value):
    return [value] if isinstance(value, dict) else (value or [])


def esc(value) -> str:
    return html.escape(str(value), quote=True)


def finite(value):
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def fmt(value, digits=0, fallback="—"):
    f = finite(value)
    return f"{f:.{digits}f}" if f is not None else fallback


def prns(value):
    if isinstance(value, (list, tuple)):
        return [int(v) for v in value]
    if not value:
        return []
    return [int(float(x)) for x in str(value).replace(",", " ").replace(";", " ").split()]


def prn_text(value, unavailable=False):
    if unavailable:
        return '<span class="pending">等待配对审计</span>'
    numbers = prns(value)
    return '<span class="prns">' + (" ".join(f"{p:02d}" for p in numbers) if numbers else "无") + "</span>"


def local_url(path: Path, page_dir: Path) -> str:
    relative = os.path.relpath(path, page_dir).replace("\\", "/")
    return quote(relative, safe="/-._~")


def link(path: Path, label: str, page_dir: Path) -> str:
    if not path.is_file():
        return ""
    return f'<a href="{esc(local_url(path, page_dir))}">{esc(label)}</a>'


def picture(path: Path, caption: str, page_dir: Path, pending="尚未生成") -> str:
    if not path.is_file():
        return f'<div class="placeholder">{esc(caption)}<br>{esc(pending)}</div>'
    url = esc(local_url(path, page_dir))
    return (f'<figure class="picture"><a href="{url}"><img loading="lazy" src="{url}" '
            f'alt="{esc(caption)}"></a><figcaption>{esc(caption)}</figcaption></figure>')


def nmea_quality(path: Path):
    if not path.exists():
        return {}
    heights = []
    for line in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        r = line.split(",")
        if len(r) < 10 or not r[0].endswith("GGA") or r[6] == "0" or not r[2] or not r[4]:
            continue
        h = finite(r[9])
        if h is not None:
            heights.append(h)
    if not heights:
        return {}
    return {"finiteEpochs": len(heights), "heightMedianM": statistics.median(heights),
            "heightMinM": min(heights), "heightMaxM": max(heights),
            "absHeightOver1000m": sum(abs(h) > 1000 for h in heights),
            "absHeightOver10000m": sum(abs(h) > 10000 for h in heights)}


def run_metrics(path: Path, entry):
    validation = read_json(path / "validation.json")
    report = read_json(path / "report.json")
    complete = bool(validation.get("pipelineOk"))
    failed = bool(validation) and not complete
    state = "已完成" if complete else ("失败，待检查" if failed else report.get("stage", "等待运行"))
    tracks = rows(validation.get("tracks", report.get("trackingSummary", [])))
    requested = validation.get("requestedMs", entry["requestedMs"])
    lengths = [finite(t.get("recordedMs")) for t in tracks]
    lengths = [x for x in lengths if x is not None]
    progress = [read_json(p) for p in path.glob("tracking_progress_prn*.json")] if path.exists() else []
    # Partial heartbeats are never represented as final tracking coverage.
    return {"path": path, "validation": validation, "report": report, "complete": complete,
            "state": state, "nAcquired": validation.get("nAcquired", report.get("nAcquired")),
            "nFixes": validation.get("nFixes", report.get("navSummary", {}).get("nFixes")),
            "fullLength": sum(x >= requested for x in lengths) if complete else None,
            "minimumRecordedSeconds": min(lengths)/1000 if lengths and complete else None,
            "maximumRecordedSeconds": max(lengths)/1000 if lengths and complete else None,
            "reacqEpisodes": sum(t.get("reacqEpisodes", 0) for t in tracks) if complete else None,
            "quality": nmea_quality(path/"pvt.nmea") if complete else {},
            "progress": progress, "requestedSeconds": requested/1000}


def metric_pair(pb, tf, key, digits=0):
    return fmt(pb.get(key), digits) + " / " + fmt(tf.get(key), digits)


def state_html(run):
    cls = "ok" if run["complete"] else "pending"
    return f'<span class="{cls}">{esc(run["state"])}</span>'


def get_settings(path):
    return read_json(path/"effective_settings.json") or read_json(path/"ui_config.json")


def source_conditions(entry, pb, tf):
    s = get_settings(pb["path"])
    gain = s.get("usrp", {}).get("gain")
    front = get_settings(tf["path"]).get("Frontend", {})
    text = (f'Fs={fmt(entry["samplingFreq"]/1e6, 2)} MHz；'
            f'Fc={fmt(entry["centerFrequencyHz"]/1e6, 2)} MHz；'
            f'接收机 IF={fmt((1176.45e6-entry["centerFrequencyHz"])/1e6, 2)} MHz；'
            f'增益={fmt(gain)} dB；请求记录={fmt(entry["requestedMs"]/1000, 3)} s；'
            f'固定幅度阈值={fmt(entry["staticPBAmplitude"], 6)} ADC。')
    if front:
        mode = front.get("mode", "")
        text += f' TF 实际 Frontend.mode={mode}。'
    return esc(text)


def station_html(entry):
    evidence = entry.get("stationEvidence", {})
    weak = entry.get("stationMatchIsWeak", False)
    name = entry.get("stationName", "未匹配") + ("（候选）" if weak else "（频谱/位置支持）")
    badge = '<span class="weak">证据弱</span>' if weak else '<span class="ok">候选匹配支持</span>'
    return (f'{esc(name)} {badge}<br>{fmt(evidence.get("frequencyHz", 0)/1e6, 0)} MHz；'
            f'{fmt(evidence.get("meanBandContrastDb"), 2)} dB<br>'
            f'<small>站距 {fmt(evidence.get("minimumDistanceKm"), 3)}–'
            f'{fmt(evidence.get("maximumDistanceKm"), 3)} km</small>')


LIST_LABELS = {
    "comparison_summary.csv": "六组对比汇总",
    "satellite_tracking_metrics.csv": "全部卫星跟踪指标",
    "continuous_tracking_intervals.csv": "连续区间起止时间",
    "no_reacq_180s.csv": "各方法 ≥180 s 无重捕卫星",
    "long_state_180s.csv": "各方法 ≥180 s LONG 状态卫星",
    "paired_satellites.csv": "PB/TF 配对卫星完整表",
    "common_no_reacq_180s.csv": "双方均 ≥180 s 无重捕",
    "common_high_elevation_180s.csv": "双方各自 ≥180 s、仰角 >30°",
    "common_high_elevation_same_interval_180s.csv": "重点：共同时间 ≥180 s、仰角 >30°",
    "common_long_high_elevation_same_interval_180s.csv": "严格：共同时间 ≥180 s、LONG 且 >30°",
}


def checklist_links(root):
    available = [link(root/"comparison"/name, label, root) for name, label in LIST_LABELS.items()]
    return '<div class="links">' + "".join(x for x in available if x) + "</div>"


def summary_table(data, include_spectrum=True):
    heads = ["实验 / 源简称", "首次有效 UTC", "站址候选 / 频带对比 / 站距"] if include_spectrum else ["实验 / 源简称"]
    heads += ["TF 数字中心 MHz", "TF 状态", "捕获 PB / TF", "全长记录 PB / TF", "最长记录 s PB / TF", "有限定位 PB / TF", "双方 ≥180 s 无重捕", "共同时间 ≥180 s 且 >30°"]
    body = []
    for d in data:
        e, pb, tf, c = d["entry"], d["pb"], d["tf"], d["comparison"]
        cells = [f'<a href="#experiment-{e["experimentNumber"]}">{e["experimentNumber"]:02d} · {esc(e["sourceId"])}</a>']
        if include_spectrum:
            cells += [esc(e["utcStart"].replace("T", " ").replace("Z", "")), station_html(e)]
        cells += [f'{fmt(e.get("tfDigitalCenterHz", 0)/1e6, 2)}<br><small>800 kHz / 3 μs</small>', state_html(tf),
                  metric_pair(pb, tf, "nAcquired"), metric_pair(pb, tf, "fullLength"),
                  metric_pair(pb, tf, "maximumRecordedSeconds", 3), metric_pair(pb, tf, "nFixes"),
                  prn_text(c.get("bothNoReacq180Prns"), not bool(c)),
                  prn_text(c.get("commonHighElevation180Prns"), not bool(c))]
        body.append("<tr>" + "".join(f"<td>{v}</td>" for v in cells) + "</tr>")
    return '<div class="scroll"><table><thead><tr>' + "".join(f"<th>{h}</th>" for h in heads) + '</tr></thead><tbody>' + "".join(body) + "</tbody></table></div>"


def findings(data):
    paired = [d for d in data if d["comparison"] and d["tf"]["complete"]]
    if len(paired) < len(data):
        return [f'当前 {sum(d["tf"]["complete"] for d in data)}/{len(data)} 组 TF 运行完成，'
                f'{len(paired)}/{len(data)} 组已有完整配对审计。未完成部分保留 pending，不据此判断 TF 优劣。']
    out = []
    for d in paired:
        c, e = d["comparison"], d["entry"]
        changes = []
        for a, b, label in [("pbAcquired", "tfAcquired", "捕获"),
                            ("pbFullLengthRecorded", "tfFullLengthRecorded", "全长记录"),
                            ("pbFiniteNavigationEpochs", "tfFiniteNavigationEpochs", "有限定位历元"),
                            ("pbReacqEpisodes", "tfReacqEpisodes", "重捕阶段")]:
            changes.append(f'{label} {fmt(c.get(a))}→{fmt(c.get(b))}')
        out.append(f'{e["experimentNumber"]:02d} {e["sourceId"]}：' + "；".join(changes) +
                   f'。共同时间 ≥180 s、双方仰角始终 >30° 的 PRN：'
                   + ("、".join(str(p) for p in prns(c.get("commonHighElevation180Prns"))) or "无") + "。")
        delta_cno = [finite(r.get("deltaCommonHighElevationMedianCnoDbHz")) for r in d.get("satellitePairs", [])
                     if r.get("commonHighElevation180")]
        delta_cno = [x for x in delta_cno if x is not None]
        if delta_cno:
            out.append(f'该组上述 {len(delta_cno)} 颗合格卫星在各自相同物理区间的 C/N₀ 中位数差（TF−PB）：'
                       f'星间中位数 {statistics.median(delta_cno):+.3f} dB-Hz，范围 '
                       f'{min(delta_cno):+.3f} 至 {max(delta_cno):+.3f} dB-Hz。该结果受入选条件限制，不代表全部捕获卫星。')
    heights = []
    for d in paired:
        c, e = d["comparison"], d["entry"]
        a, b = finite(c.get("pbAbsHeightOver1000m")), finite(c.get("tfAbsHeightOver1000m"))
        if a or b:
            heights.append(f'{e["sourceId"]} {fmt(a)}→{fmt(b)}')
    if heights:
        out.append('原始解中 |高程|>1000 m 的异常候选历元（PB→TF）：' + "；".join(heights) + '。该阈值只作质量提示，原始定位结果均保留。')
    out.append('上述变化必须分别评价，捕获数、连续跟踪、重捕阶段和定位稳定性可能给出不同结论。PB/TF 位置差是两方法的一致性指标；未提供外部真值，不能据此声称绝对定位精度提高。')
    return out


def run_links(run, root):
    names = ["ui_config.json", "effective_settings.json", "validation.json", "report.json", "acquisition_summary.csv", "tracking_summary.csv", "pvt.nmea"]
    links = [link(run["path"]/name, name, root) for name in names]
    recovery = read_json(run["path"]/"recovery_plan.json")
    links.append(link(run["path"]/"matlab.log", "崩溃前运行日志" if recovery else "matlab.log", root))
    if recovery:
        number = int(recovery["experimentNumber"])
        links += [link(run["path"]/name, label, root) for name, label in [
            ("recovery_plan.json", "逐星恢复计划"),
            ("recovery_condition_check.json", "恢复参数核验"),
            ("recovery_state.mat", "恢复参数与通道映射 MAT")]]
        paths = [root/f"recovery_prepare_{number:02d}.log"]
        paths += sorted(root.glob(f"recovery_track_{number:02d}_prn*.log"))
        paths.append(root/f"recovery_finish_{number:02d}.log")
        links += [link(path, path.name, root) for path in paths]
    links += [link(p, "完整结果 MAT", root) for p in sorted(run["path"].glob("run_B2a_*.mat"))]
    return '<div class="links">' + "".join(x for x in links if x) + "</div>"


def section(d, root):
    e, pb, tf, c = d["entry"], d["pb"], d["tf"], d["comparison"]
    number = e["experimentNumber"]
    a = root/"analysis"/f'{number:02d}_{e["sourceId"]}'
    content = [f'<section id="experiment-{number}"><h2>{number:02d} · {esc(e["sourceId"])} · {esc(e["stationName"])}'
               + ('（弱候选）' if e.get("stationMatchIsWeak") else '') + '</h2>',
               f'<p class="statline">UTC {esc(e["utcStart"])} 至 {esc(e["utcEnd"])}。PB {state_html(pb)}；TF {state_html(tf)}</p>',
               f'<p>{source_conditions(e,pb,tf)}</p><p><small>源文件：<code>{esc(e["sourceFile"])}</code></small></p>']
    if e.get("stationMatchIsWeak"):
        content.append('<p class="notice">官庄仅为参考站弱候选：1181 MHz 频带比局部背景高约 0.55 dB，接收前端频响也可能造成小幅凸起，不能确认存在官庄 DME 干扰。该组 TF 按 1181 MHz 参考中心运行，用作弱干扰条件下的对照。</p>')
    content += ['<h3>原始 IQ 频谱与参考站证据</h3><div class="pair">',
                picture(a/"raw_fft_fullband.png", "全频带 Welch PSD / 时间频率图 / 分窗频带对比", root),
                picture(a/"station_band_zoom.png", "1170 / 1173 / 1181 MHz 参考频带局部图", root), '</div>',
                '<div class="links">' + "".join(link(a/name, label, root) for name, label in [
                    ("spectral_station_evidence.json", "频谱与站距证据 JSON"), ("station_candidates.csv", "三站候选指标 CSV"),
                    ("welch_spectrum.csv", "频谱 CSV"), ("window_diagnostics.csv", "分窗指标 CSV"), ("spectral_data.mat", "频谱 MAT")]) + '</div>',
                '<h3>卫星底图轨迹：PB / TF</h3><div class="pair">',
                picture(pb["path"]/"figures/navResult/lla_satellite_dme.png", "PB：时间由紫色渐变至橘色；参考站与轨迹共同定界", root, "等待卫星地图导出"),
                picture(tf["path"]/"figures/navResult/lla_satellite_dme.png", "TF：与 PB 使用相同成对地图范围及色盘", root, "等待 TF 完成及卫星地图导出"), '</div>']
    if c:
        content.append('<div class="kv"><div>PB ≥180 s 无重捕：' + prn_text(c.get("pbNoReacq180Prns")) +
                       '<br>TF ≥180 s 无重捕：' + prn_text(c.get("tfNoReacq180Prns")) + '</div><div>共同物理时间 ≥180 s 且双方 >30°：' +
                       prn_text(c.get("commonHighElevation180Prns")) + '<br>更严格共同 LONG 且 >30°：' +
                       prn_text(c.get("commonLongHighElevation180Prns")) + '</div></div>')
    for label, run in [("PB", pb), ("TF", tf)]:
        content.append(f'<details><summary>{label} 捕获、导航及每星跟踪图 / 原始结果</summary>')
        content.append(run_links(run, root))
        if run["complete"]:
            content.append(f'<p>捕获 {fmt(run["nAcquired"])}；全长记录 {fmt(run["fullLength"])}；记录时长范围 '
                           f'{fmt(run["minimumRecordedSeconds"],3)}–{fmt(run["maximumRecordedSeconds"],3)} s；有限定位 {fmt(run["nFixes"])}。</p>')
        else:
            content.append('<p class="muted">当前状态：' + esc(run["state"]) + '。以下仅显示已写出的产物。</p>')
        paths = sorted((run["path"]/"figures").glob("AcqResult/*.png"))
        paths += [p for p in sorted((run["path"]/"figures").glob("navResult/*.png")) if p.name not in ("lla_geobasemap.png", "lla_satellite_dme.png")]
        paths += sorted((run["path"]/"figures").glob("trkResult/*.png"))
        content.append('<div class="gallery three">' + "".join(picture(p, f'{label} · {p.stem}', root) for p in paths) + '</div></details>')
    content.append('</section>')
    return "".join(content)


def document(title, body):
    return f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title><style>{CSS}</style></head><body><main>{body}</main></body></html>'


def common_method_text():
    return ('<p>排序使用每次定位的首次有效 GGA UTC 和 ZDA 日期，日期均为 2022-10-20；并非文件名的本地时间。'
            '六组均搜索 B2a PRN 1–63，保留各文件采样率、RF 中心、增益、捕获与跟踪参数、处理起点和请求时长。'
            'PB 每文件由全时段抽样估计后固定的幅度阈值沿用至 TF 检测器；主要改变为静态时域 PB → TFBlankerV1，陷波宽度 800 kHz、三角时间核跨度 3 μs。'
            'TF 数字中心 = 参考站 RF 频率 − 采集 RF 中心。为降低主机负载，TF 运行限制并行资源并隐藏图窗。</p>'
            '<p>FFT 使用未抑制的原始 int16 I+jQ，61 个均匀分布的 50 ms 窗，8192 点周期 Hann、50% 重叠，分辨率约 2.441 kHz。'
            '“频带对比”是站频率 ±400 kHz 的平均 PSD 相对距中心 0.8–1.4 MHz 两侧背景；另保存最高能量 10% FFT 帧频谱。'
            '谱峰及站距支持候选关联，不能唯一识别发射台；不同采集增益下不直接比较绝对 ADC 功率。</p>'
            '<p>全长记录表示保存记录数覆盖请求时长，允许中途失锁及重捕。≥180 s 筛选另根据原始采样位置检查连续物理时间，'
            '区分无重捕与更严格 LONG 状态；仰角筛选要求双方同一共同时间段内均 >30°。未知仰角及数据间断不视为满足条件。'
            '地图使用接收机原有 500 m/s 跳点过滤，原始解保留；地图范围由两方法轨迹与匹配参考站共同边界扩展，紫→橘表示时间推进。</p>'
            '<p>有限定位历元仅表示产生有限坐标的次数，不等于可信定位，更不等于定位精度。未提供独立参考轨迹；'
            'PB/TF 位置差只能衡量两方法一致性，不能据此声称绝对精度提高。</p>')


def recovery_notes(root):
    audit_path = root/"recovery_audit.json"
    if not read_json(audit_path):
        return ""
    evidence_path = root/"analysis/recovered_prn25_chunk001_verification.json"
    evidence = read_json(evidence_path)
    replay_note = ""
    if evidence.get("ok") is True:
        replay_note = ('<p>PRN 25 归档分段与串行重算的第 1 个分段（首 60000 条保存记录）逐字段比较一致：'
                       '83 项数值/逻辑数据集和 8 项字符元数据。此证据仅覆盖该分段，不外推至全部历元或其他卫星；'
                       '两个 MAT 容器的文件哈希可以不同，数值一致性以逐字段比较为据。</p>')
    return ('<div class="notice"><strong>崩溃后的恢复范围</strong>'
            '<p>第 5 组的恢复方案保留崩溃前已保存的 8 份逐星 final（其中 2 颗已提前结束），'
            'PRN 25 和 30 按整颗从原始数据重新计算；不将 PRN 25 的部分分段拼接为续跟踪。'
            '分段文件保存的是跟踪输出，不是完整环路 checkpoint。</p>'
            '<p>第 5 组的补算及第 6 组使用单个 R2024b 进程、单计算线程、逐星串行且不启动并行池：'
            '<code>useParfor=false</code>、<code>useParallelAcquisition=false</code>、'
            '<code>parMaxWorkers=1</code>。第 5 组的 8 份既有 final 来自原两 worker 运行，'
            '保存的最终资源配置描述恢复阶段；接收机数值源码、源数据和科学参数保持原条件。'
            '资源调度调整不作为干扰抑制效果，恢复完成状态仍以各组验证结果为准。'
            '第 5 组耗时字段仅统计恢复工作，不用于与未中断运行作耗时比较。</p>'
            +replay_note+'<div class="links">'+link(audit_path,"恢复范围与复用文件审计",root)+
            link(evidence_path,"PRN 25 首分段数值一致性证据",root)+'</div></div>')


def navigation_figure_notes(root):
    audit_path = root/"analysis/navigation_figure_verification.json"
    audit = read_json(audit_path)
    if not audit:
        return ""
    completed = audit.get("completedRuns", 0)
    return (f'<div class="notice"><strong>导航图显示层核验：{esc(completed)}/12 组</strong>'
            '<p>PB/TF 导航图统一从已保存的导航结果逐图离线导出，保持原轨迹过滤、ENU 参考和速度定义；'
            '天空图按原通道槽位与历元匹配 PRN 和方位/仰角，仅显示 0–90° 仰角。'
            '此步骤不重新定位、不修改导航数组；源 MAT 的大小和修改时间在导出前后核验。'
            '临时离线轨迹预览随后由最终卫星底图与 DME 站址图覆盖。</p>'
            '<div class="links">'+link(audit_path,"12 组导航图显示层核验",root)+'</div></div>')


def tracking_figure_notes(root):
    audit_path=root/"analysis/tracking_figure_verification.json"
    audit=read_json(audit_path)
    if not audit:
        return ""
    links="".join(link(root/path,label,root) for path,label in [
        ("analysis/tracking_figure_verification.json","跟踪图单位与源文件核验"),
        ("analysis/acquisition_figure_verification.json","63 PRN 捕获图核验"),
        ("postprocessing_complete.json","绘图后处理完成记录")])
    return ('<div class="notice"><strong>跟踪图的时间轴与单位</strong>'
            '<p>跟踪图保留“名义跟踪时间”横轴，即记录行索引 × 积分时间；C/N₀ 按名义 CNoInterval 间距显示。'
            '重捕后，该横轴不一定等于原始采样文件的物理时间。180 s 筛选采用 absoluteSample / samplingFreq '
            '及实际每段采样数，不能从图上名义横轴的跨度直接认定。</p>'
            '<p>PLL 使用双纵轴：左轴为保存的相位鉴别误差（cycles），右轴为载波 NCO（Hz）；'
            'DLL 左轴为无量纲 (E−L)/(E+L)，右轴为码 NCO（chips/s）。NCO 频率输出不是相位误差，'
            '不能将旧变量名 pllDiscrFilt / dllDiscrFilt 当作同单位的“滤波后误差”。</p>'
            '<p>状态图保留全部状态转换点，包括短暂的 REACQ。重捕期间相关器、鉴别器和 NCO 的零值占位保留，'
            '不表示实际误差为零。后处理仅从保存的 MAT 重画，未重跑接收机；源 MAT 的大小和修改时间核验见记录。</p>'
            '<div class="links">'+links+'</div></div>')


def build_brief(root, data, comparison, generated):
    ready = sum(bool(d["comparison"]) for d in data)
    body = ['<div class="card hero"><h1>DATA1020 · PB / TF 实验对比简报</h1>',
            f'<p class="lead">配对审计 {ready}/{len(data)} 组。生成时间 {esc(generated)}。</p>',
            '<div class="links">' + link(root/"index.html", "返回完整图册", root) +
            link(root/"comparison/comparison_report.json", "机器可读完整对比", root) +
            link(root/"comparison/comparison_brief.html", "数值审计明细", root) +
            link(root/"source_manifest.json", "启动时源码证据", root) +
            link(root/"final_source_manifest.json", "最终源码溯源与变更", root) + '</div></div>',
            '<section><h2>实验设计与边界</h2>', common_method_text(), recovery_notes(root), navigation_figure_notes(root), tracking_figure_notes(root),
            '<p>原始 HUR 组已从本轮分析排除并删除对应实验结果；原始 <code>data_1020_HUR.bin</code> 暂保留。HUR_1 和 HUR_2 为独立实验，仍纳入。</p>',
            '<p class="notice">beiqijiatai 的 1181 MHz 频带仅高于局部背景约 0.55 dB，官庄为弱候选，前端频响也可能造成该凸起。'
            '其余五组 1170 MHz 明显谱结构与近怀柔路线一致。本站归因均为频谱与位置证据推断，未解码站台标识。</p></section>',
            '<section><h2>实际对比结果</h2>', summary_table(data, False),
            '<p class="muted">表中成对数字按 PB / TF 排列；有限定位历元不等于可信解，更不等于定位精度。</p>',
            "".join(f'<p>{esc(p)}</p>' for p in findings(data)), '</section>',
            '<section><h2>导航质量与双方位置一致性</h2>']
    heads = ["实验", "重捕阶段 PB / TF", "原始高程中位数 m PB / TF", "|高程|>1000m PB / TF", "绘图剔除 PB / TF", "双方平面差中位数 / P95 m"]
    body.append('<div class="scroll"><table><thead><tr>' + ''.join(f'<th>{h}</th>' for h in heads) + '</tr></thead><tbody>')
    for d in data:
        c, e = d["comparison"], d["entry"]
        values = [f'{e["experimentNumber"]:02d} {esc(e["sourceId"])}']
        for a, b, digits in [("pbReacqEpisodes", "tfReacqEpisodes", 0), ("pbHeightMedianM", "tfHeightMedianM", 2),
                             ("pbAbsHeightOver1000m", "tfAbsHeightOver1000m", 0), ("pbRemovedJumpEpochs", "tfRemovedJumpEpochs", 0),
                             ("medianHorizontalDisagreementM", "p95HorizontalDisagreementM", 2)]:
            values.append(fmt(c.get(a), digits) + ' / ' + fmt(c.get(b), digits))
        body.append('<tr>' + ''.join(f'<td>{v}</td>' for v in values) + '</tr>')
    body.append('</tbody></table></div><p>双方位置差使用相同源数据时间的有效过滤轨迹对齐，只说明方法间一致性。未提供参考真值，不作绝对精度或准确度结论。</p></section>')
    body.append('<section><h2>卫星筛选清单</h2>' + checklist_links(root))
    body.append('<p>推荐重点表为“共同时间 ≥180 s、仰角 >30°”。它比“PB 和 TF 分别拥有任意 180 s 合格区间”更严格，适合取同一原始片段作后续逐星对比。'
                '更严格的 LONG 清单另外要求跟踪状态为 3/4；各 CSV 保留原始 MAT 与跟踪图路径。</p></section>')
    body.append('<section><h2>逐组条件与连续跟踪名单</h2>')
    for d in data:
        e, c = d["entry"], d["comparison"]
        body.append(f'<h3 id="experiment-{e["experimentNumber"]}">{e["experimentNumber"]:02d} {esc(e["sourceId"])}</h3><p>' + source_conditions(e,d["pb"],d["tf"]) + '</p>')
        body.append('<p>PB ≥180 s 无重捕：' + prn_text(c.get("pbNoReacq180Prns"), not bool(c)) +
                    '；TF：' + prn_text(c.get("tfNoReacq180Prns"), not bool(c)) +
                    '；双方共同 ≥180 s 且 >30°：' + prn_text(c.get("commonHighElevation180Prns"), not bool(c)) + '。</p>')
    body.append('</section>')
    return document('DATA1020 PB / TF 对比简报', ''.join(body))


class LocalLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []
    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key in ("href", "src") and value:
                self.urls.append(value)


def verify_links(pages):
    errors, checked = [], 0
    for page in pages:
        parser = LocalLinks()
        parser.feed(page.read_text(encoding="utf-8"))
        for url in parser.urls:
            parsed = urlsplit(url)
            if parsed.scheme or not parsed.path:
                continue
            target = page.parent/unquote(parsed.path)
            checked += 1
            if not target.exists():
                errors.append({"page": page.name, "url": url})
    return {"checkedLocalReferences": checked, "missingLocalReferences": errors, "ok": not errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = read_json(root/"manifest.json")
    if not manifest:
        raise SystemExit('manifest.json is required')
    spectrum = read_json(root/"analysis/fft_station_analysis.json")
    spectrum_by_id = {r["sourceId"]: r for r in rows(spectrum.get("entries", []))}
    comparison = read_json(root/"comparison/comparison_report.json")
    comparisons = {r["summary"]["sourceId"]: r["summary"] for r in rows(comparison.get("experiments", []))}
    for row in read_csv(root/"comparison/comparison_summary.csv"):
        comparisons.setdefault(row["sourceId"], row)
    data = []
    for entry in sorted(manifest["entries"], key=lambda e:e["utcStart"]):
        evidence = spectrum_by_id.get(entry["sourceId"], {})
        entry.setdefault("stationEvidence", evidence.get("matchedStation", {}))
        data.append({"entry":entry, "pb":run_metrics(Path(entry["pbDir"]), entry),
                     "tf":run_metrics(Path(entry["tfDir"]), entry), "comparison":comparisons.get(entry["sourceId"], {}),
                     "satellitePairs":[r for r in rows(comparison.get("pairedSatellites", [])) if r.get("sourceId")==entry["sourceId"]]})
    generated = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S UTC+08:00')
    complete = sum(d["tf"]["complete"] for d in data)
    body = ['<div class="card hero"><h1>DATA1020 · 静态 PB 与 TFBlankerV1</h1>',
            '<p class="lead">六组实验按首次有效定位 UTC 排序；原始频谱、候选 DME 站、卫星底图轨迹、逐星跟踪及配对筛选集中浏览。</p>',
            f'<p>PB 完成 {sum(d["pb"]["complete"] for d in data)}/{len(data)}；TF 完成 {complete}/{len(data)}。生成时间 {esc(generated)}。</p>',
            '<div class="links">' + ''.join(link(root/path,label,root) for path,label in [
                ('comparison_brief.html','实验对比简报'),('manifest.json','实验条件与站匹配'),
                ('analysis/fft_station_analysis.json','FFT 分析完整证据'),('comparison/comparison_summary.csv','对比汇总 CSV'),
                ('source_manifest.json','启动时源码证据'),('final_source_manifest.json','最终源码溯源与变更')]) + '</div></div>',
            '<nav class="topnav"><a href="#overview">总表</a><a href="#criteria">方法与条件</a><a href="#lists">卫星清单</a>' + ''.join(
                f'<a href="#experiment-{d["entry"]["experimentNumber"]}">{d["entry"]["experimentNumber"]:02d} {esc(d["entry"]["sourceId"])}</a>' for d in data) + '</nav>',
            '<section id="overview"><h2>实验总表</h2>', summary_table(data),
            '<p class="muted">成对数字为 PB / TF。“全长记录”允许中途重捕；持续无重捕须查看独立 180 s 清单。空缺显示 — 或 pending，绝不作为零结果。</p></section>',
            '<section id="criteria"><h2>方法、条件与质量边界</h2>', common_method_text(), recovery_notes(root), navigation_figure_notes(root), tracking_figure_notes(root),
            '<p class="notice">原始 HUR 组已排除，仅对应实验结果删除；raw bin 暂保留。HUR_1、HUR_2 继续参与。'
            'beiqijiatai→官庄是弱候选，约 0.55 dB 凸起也可能由前端频响造成；其余五组支持怀柔 1170 MHz 候选关联。</p></section>',
            '<section id="lists"><h2>完整对比与卫星清单</h2>', checklist_links(root),
            '<p>重点清单采用双方共同物理时间连续 ≥180 s、仰角始终 >30°；另保留双方各自满足条件和更严格 LONG 状态清单。</p>',
            '<div class="links">' + link(root/'comparison/comparison_brief.html','数值审计简报',root) + link(root/'comparison/comparison_report.json','对比 JSON',root) + '</div></section>']
    body.extend(section(d,root) for d in data)
    (root/'index.html').write_text(document('DATA1020 PB / TF 实验图册',''.join(body)),encoding='utf-8')
    (root/'comparison_brief.html').write_text(build_brief(root,data,comparison,generated),encoding='utf-8')
    # The index is generated first so both cross-page links exist on initial run.
    index_text=(root/'index.html').read_text(encoding='utf-8')
    if 'href="comparison_brief.html"' not in index_text:
        index_text=index_text.replace('<div class="links">','<div class="links"><a href="comparison_brief.html">实验对比简报</a>',1)
        (root/'index.html').write_text(index_text,encoding='utf-8')
    checked = verify_links([root/'index.html', root/'comparison_brief.html'])
    checked.update({'generatedAt':generated,'pbCompleted':sum(d['pb']['complete'] for d in data),'tfCompleted':complete,
                    'comparisonGroups':len(comparisons),'experimentCount':len(data)})
    (root/'report_link_verification.json').write_text(json.dumps(checked,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(checked,ensure_ascii=True))
    if not checked['ok']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
