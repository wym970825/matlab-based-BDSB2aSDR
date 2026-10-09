"""Low-memory final audit for the six DATA1020 PB/TF experiment pairs.

Read JSON/CSV/NMEA and artifact headers; do not load MAT arrays or run MATLAB.
Source IQ verification uses byte counts, timestamps, and three 64-KiB sample
hashes, not a costly full-file hash. Its first invocation records the reference
snapshot. Use --allow-pending while the receiver queue is still running.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import re
import struct
from urllib.parse import unquote, urlsplit
from record_data1020_recovery import verify_replayed_chunk


ALLOWED_SETTING_CHANGES = {
    "Frontend", "EnablePB", "parMaxWorkers", "useParfor", "useParallelAcquisition",
    "tag", "outDir", "resultRoot", "tempdataSvPth",
}
EXPECTED_IDS = {"beiqijiatai", "HUR_1", "HUR_2", "103330", "103801", "111407"}
EXPECTED_PRNS = list(range(1, 64))
NAV_PNGS = ["dop.png", "enu_displacement.png", "enu_velocity.png", "sky_plot.png",
            "lla_geobasemap.png", "lla_satellite_dme.png"]


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def read_csv(path):
    try:
        with Path(path).open(encoding="utf-8-sig", newline="") as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []


def rows(value):
    if not value:
        return []
    return [value] if isinstance(value, dict) else value


def close(a, b, tolerance=1e-9):
    try:
        return math.isclose(float(a), float(b), rel_tol=tolerance, abs_tol=tolerance)
    except (TypeError, ValueError):
        return False


def truth(value):
    return value is True or str(value).lower() in ("1", "true")


def prns(value):
    if not value:
        return []
    if isinstance(value, (list, tuple)):
        return sorted(int(v) for v in value)
    return sorted(int(float(v)) for v in str(value).replace(",", " ").split())


def canonical(path):
    return os.path.normcase(os.path.abspath(path))


def hash_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as f:
        while block := f.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def input_fingerprint(path):
    path = Path(path)
    stat = path.stat()
    length = min(65536, stat.st_size)
    offsets = sorted({0, (max(0, stat.st_size//2-length//2)//4)*4,
                      (max(0, stat.st_size-length)//4)*4})
    samples = []
    with path.open("rb") as f:
        for offset in offsets:
            f.seek(offset)
            block = f.read(length)
            samples.append({"offsetBytes": offset, "lengthBytes": len(block),
                            "sha256": hashlib.sha256(block).hexdigest()})
    return {"path": str(path), "sizeBytes": stat.st_size, "mtimeNs": stat.st_mtime_ns,
            "sampleHashes": samples}


def png_header(path):
    try:
        with Path(path).open("rb") as f:
            header = f.read(24)
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            return None
        width, height = struct.unpack(">II", header[16:24])
        return {"width": width, "height": height, "sizeBytes": Path(path).stat().st_size}
    except OSError:
        return None


def first_gga(path):
    lines = Path(path).read_text(encoding="utf-8-sig", errors="replace").splitlines()
    date = None
    valid = []
    for line in lines:
        r = line.split(",")
        if len(r) >= 5 and r[0].endswith("ZDA") and date is None:
            date = dt.date(int(r[4]), int(r[3]), int(r[2]))
        if len(r) >= 10 and r[0].endswith("GGA") and r[6] != "0" and r[2] and r[4]:
            valid.append(r)
    if not valid or date is None:
        return None, len(valid)
    t = valid[0][1]
    when = dt.datetime.combine(date, dt.time(tzinfo=dt.timezone.utc)) + dt.timedelta(
        hours=int(t[:2]), minutes=int(t[2:4]), seconds=float(t[4:]))
    return when, len(valid)


class Audit:
    def __init__(self):
        self.checks = []
    def check(self, name, condition, details=None, pending=False):
        status = "passed" if condition else ("pending" if pending else "failed")
        row = {"check": name, "status": status}
        if details is not None:
            row["details"] = details
        self.checks.append(row)
        return bool(condition)
    def required(self, path, label, pending=False, minimum_bytes=1):
        path = Path(path)
        return self.check(label, path.is_file() and path.stat().st_size >= minimum_bytes,
                          {"path": str(path)}, pending=pending)


def validate_settings(audit, prefix, settings, entry, mode):
    expected_if = 1176.45e6-entry["centerFrequencyHz"]
    values = {"dataType": "int16", "fileType": 2, "samplingFreq": entry["samplingFreq"],
              "IF": expected_if, "IFBandwidth": 20e6, "skipNumberOfBytes": 0,
              "numberOfChannels": 63, "msToProcess": entry["requestedMs"]}
    wrong = {k: {"expected": v, "actual": settings.get(k)} for k, v in values.items()
             if settings.get(k) != v}
    audit.check(prefix+" input format and duration", not wrong, wrong)
    audit.check(prefix+" all PRNs configured", prns(settings.get("acqSatelliteList")) == EXPECTED_PRNS)
    source = Path(settings.get("filePath", ""))/settings.get("fileName", "")
    audit.check(prefix+" source path", canonical(source) == canonical(entry["sourceFile"]))
    audit.check(prefix+" gain", settings.get("usrp", {}).get("gain") == (0 if entry["sourceId"]=="111407" else 30))
    pb = settings.get("PB_settings", {})
    audit.check(prefix+" frozen threshold preserved", truth(pb.get("UseStatic")) and
                close(pb.get("Th_static"), entry["staticPBAmplitude"]) and
                close(pb.get("Th_static_tracking"), entry["staticPBAmplitude"]))
    frontend = settings.get("Frontend", {})
    if mode == "PB":
        audit.check(prefix+" PB frontend", frontend.get("mode")=="pb" and truth(settings.get("EnablePB")))
    else:
        audit.check(prefix+" TF frontend", frontend.get("mode")=="tf_v1" and not truth(settings.get("EnablePB")))
        tf = frontend.get("TF", {})
        expected = {"centerHz": entry["station"]["frequencyHz"]-entry["centerFrequencyHz"],
                    "stopbandWidthHz": 800e3, "triangleSpanUs": 3, "actualTriangleSpanUs": 3,
                    "effectiveThresholdAmplitude": entry["staticPBAmplitude"],
                    "effectiveTaps": 513, "K": 30, "H": 356}
        wrong = {k:{"expected":v,"actual":tf.get(k)} for k,v in expected.items() if not close(tf.get(k),v)}
        audit.check(prefix+" resolved TF parameters", not wrong, wrong)
        audit.check(prefix+" worker limit", 0 <= settings.get("parMaxWorkers", 99) <= 2)
        serial_recovery = entry["experimentNumber"] in (5, 6)
        resource_expected = {"useParfor": not serial_recovery,
                             "useParallelAcquisition": not serial_recovery}
        if serial_recovery:
            resource_expected["parMaxWorkers"] = 1
        resource_wrong = {k: {"expected": v, "actual": settings.get(k)}
                          for k, v in resource_expected.items() if settings.get(k) != v}
        audit.check(prefix+" scheduled resource settings", not resource_wrong, resource_wrong)


def validate_run(audit, entry, mode):
    run = Path(entry["pbDir"] if mode=="PB" else entry["tfDir"])
    prefix = f'{entry["experimentNumber"]:02d} {mode}'
    val = read_json(run/"validation.json")
    complete = bool(val.get("pipelineOk"))
    audit.check(prefix+" pipeline complete", complete, val.get("error") or val.get("stage", "pending"), pending=not bool(val))
    if not complete:
        return {"complete": False, "settings": {}, "acquiredPrns": []}
    settings = read_json(run/"effective_settings.json")
    audit.check(prefix+" saved effective settings", bool(settings))
    if settings:
        validate_settings(audit,prefix,settings,entry,mode)
    audit.check(prefix+" searched PRNs", prns(val.get("searchedPrns"))==EXPECTED_PRNS)
    table = read_csv(run/"acquisition_summary.csv")
    searched = sorted(int(r["PRN"]) for r in table)
    detected = sorted(int(r["PRN"]) for r in table if truth(r.get("detected")))
    audit.check(prefix+" 63 acquisition CSV rows", len(table)==63 and searched==EXPECTED_PRNS)
    acquired = prns(val.get("acquiredPrns"))
    audit.check(prefix+" acquired count and mask consistent", acquired==detected and len(acquired)==val.get("nAcquired"))
    tracks = rows(val.get("tracks"))
    audit.check(prefix+" all acquired satellites tracked", truth(val.get("allAcquiredTracked")) and
                sorted(int(t["PRN"]) for t in tracks)==acquired)
    actual_mat = sorted(int(re.search(r"Trk_Prn_(\d+)_final\.mat",p.name).group(1))
                        for p in (run/"temp").glob("Trk_Prn_*_final.mat"))
    actual_png = sorted(int(re.search(r"PRN_(\d+)_tracking\.png",p.name).group(1))
                        for p in (run/"figures/trkResult").glob("PRN_*_tracking.png"))
    audit.check(prefix+" per-PRN MAT set", actual_mat==acquired)
    audit.check(prefix+" per-PRN PNG set", actual_png==acquired)
    full_mats = list(run.glob("run_B2a_*.mat"))
    audit.check(prefix+" complete run MAT", len(full_mats)==1 and full_mats[0].stat().st_size>1024)
    for name in ["ui_results.mat","pvt.nmea","tracking_summary.csv"]:
        audit.required(run/name,prefix+" "+name)
    nmea = run/"pvt.nmea"
    if nmea.exists():
        utc, count = first_gga(nmea)
        audit.check(prefix+" NMEA count agrees with navigation", count==val.get("nFixes"),{"nmea":count,"validation":val.get("nFixes")})
        if utc is not None:
            expected = dt.datetime.fromisoformat(entry["utcStart"].replace("Z","+00:00"))
            audit.check(prefix+" UTC agrees with experiment", abs((utc-expected).total_seconds()) <
                        (0.011 if mode=="PB" else entry["requestedMs"]/1000), {"firstValidUtc":utc.isoformat()})
        else:
            audit.check(prefix+" has valid UTC",False)
    for name in NAV_PNGS:
        # Satellite maps are exported after all TF runs; pending is separate.
        audit.required(run/"figures/navResult"/name,prefix+" navigation "+name,pending=name=="lla_satellite_dme.png")
    audit.required(run/"figures/AcqResult/acquisition_metrics.png",prefix+" acquisition figure")
    damaged = []
    for p in (run/"figures").rglob("*.png"):
        info = png_header(p)
        if not info or min(info["width"],info["height"])<100 or info["sizeBytes"]<1024:
            damaged.append(str(p))
    audit.check(prefix+" PNG headers and dimensions",not damaged,damaged)
    if mode=="TF":
        condition = read_json(run/"condition_verification.json")
        audit.check(prefix+" MATLAB condition audit",truth(condition.get("onlyAllowedChanges")) and not condition.get("forbiddenFields"))
        filt = read_json(run/"filter_verification.json")
        audit.check(prefix+" TF direct-convolution audit",truth(filt.get("ok")) and
                    float(filt.get("relativeErrorToDirectConvolution",1))<1e-11 and
                    close(filt.get("centerHz"),entry["tfDigitalCenterHz"]) and
                    close(filt.get("thresholdAmplitude"),entry["staticPBAmplitude"]))
        audit.check(prefix+" threshold matches baseline",truth(val.get("thresholdMatchesBaseline")))
    return {"complete":True,"settings":settings,"acquiredPrns":acquired,"nFixes":val.get("nFixes"),
            "fullLength":sum(t.get("recordedMs",0)>=entry["requestedMs"] for t in tracks),
            "nAcquired":len(acquired)}


def validate_maps(audit,root,entries):
    records = rows(read_json(root/"analysis/satellite_maps/satellite_map_verification.json"))
    lookup = {(int(r["experimentNumber"]),r["method"]):r for r in records}
    for e in entries:
        number=e["experimentNumber"]
        for mode in ["PB","TF"]:
            r=lookup.get((number,mode),{})
            if not audit.check(f'{number:02d} {mode} satellite map audit',bool(r),pending=True):
                continue
            b=r.get("contentBoundsWestSouthEastNorth",[]); m=r.get("mapBoundsWestSouthEastNorth",[])
            center=r.get("mapCenterLongitudeLatitude",[])
            good=len(b)==4 and len(m)==4 and m[0]<b[0] and m[1]<b[1] and m[2]>b[2] and m[3]>b[3]
            audit.check(f'{number:02d} {mode} map encloses track and station',good)
            audit.check(f'{number:02d} {mode} map centered on content rectangle',len(center)==2 and
                        close(center[0],(b[0]+b[2])/2,1e-10) and close(center[1],(b[1]+b[3])/2,1e-10))
            stations=rows(r.get("stations"))
            audit.check(f'{number:02d} {mode} matching station on map',any(s.get("id")==e["stationId"] and
                        close(s.get("frequencyHz"),e["station"]["frequencyHz"]) for s in stations))
            audit.check(f'{number:02d} {mode} purple-orange palette',r.get("palette",{}).get("name")=="Muted purple-orange sequential")
            audit.check(f'{number:02d} {mode} satellite attribution',"Esri" in r.get("attribution","") and bool(r.get("tileManifest")))
        a,b=lookup.get((number,"PB"),{}),lookup.get((number,"TF"),{})
        audit.check(f'{number:02d} paired maps share bounds',bool(a and b) and
                    a.get("mapBoundsWestSouthEastNorth")==b.get("mapBoundsWestSouthEastNorth") and
                    a.get("pairedBoundsIncludePB") and a.get("pairedBoundsIncludeTF") and
                    b.get("pairedBoundsIncludePB") and b.get("pairedBoundsIncludeTF"),pending=not bool(a and b))


def validate_navigation_figures(audit, root, entries, runs):
    nav = read_json(root/"analysis/navigation_figure_verification.json")
    complete = nav.get("ok") is True
    if not audit.check("navigation display audit exists", bool(nav), pending=True):
        return
    records = rows(nav.get("records"))
    expected = {(e["experimentNumber"], mode) for e in entries for mode in ["PB", "TF"]}
    actual = {(r.get("experimentNumber"), r.get("method")) for r in records}
    audit.check("twelve navigation display audit records", complete and
                nav.get("expectedRuns") == nav.get("completedRuns") == len(records) == 12 and
                actual == expected, pending=not complete)
    audit.check("navigation source audit scope is size and timestamp",
                nav.get("sourceCheck") == "File size and modification timestamp before/after each export")
    by_number = {e["experimentNumber"]: e for e in entries}
    names = {"enu_displacement.png", "enu_velocity.png", "dop.png", "sky_plot.png", "lla_geobasemap.png"}
    post_complete = read_json(root/"postprocessing_complete.json").get("ok") is True
    for record in records:
        key = (record.get("experimentNumber"), record.get("method"))
        prefix = f'{key[0]} {key[1]} navigation display'
        if not audit.check(prefix+" belongs to manifest", key in expected):
            continue
        entry = by_number[key[0]]
        run = Path(entry["pbDir"] if key[1] == "PB" else entry["tfDir"])
        source, output = run/"ui_results.mat", run/"figures/navResult"
        audit.check(prefix+" input and output identities",
                    canonical(record.get("runDir", "")) == canonical(run) and
                    canonical(record.get("sourceMat", "")) == canonical(source))
        audit.check(prefix+" source unchanged during export",
                    record.get("sourceUnchanged") is True and source.is_file() and
                    source.stat().st_size == record.get("sourceBytes") == record.get("sourceAfterBytes") and
                    record.get("sourceDatenum") == record.get("sourceAfterDatenum"))
        fig = record.get("figureAudit", {})
        local = read_json(output/"navigation_figure_verification.json")
        audit.check(prefix+" per-run audit agrees with aggregate", bool(local) and local == fig)
        audit.check(prefix+" offline sequential presentation only",
                    fig.get("ok") is True and fig.get("skippedReason") == "" and
                    fig.get("visible") is False and fig.get("maxSimultaneousFigures") == 1 and
                    fig.get("onlineBasemap") is False and fig.get("navigationDataModified") is False and
                    fig.get("navigationRecomputed") is False and
                    fig.get("sourceDefinition") == "plotNavPost + navTrackTimeOrder" and
                    canonical(fig.get("saveDir", "")) == canonical(output))
        paths = fig.get("figureFiles", [])
        audit.check(prefix+" five expected navigation outputs", len(paths) == 5 and
                    {canonical(p) for p in paths} == {canonical(output/n) for n in names})
        outputs = rows(fig.get("figureOutputs"))
        audit.check(prefix+" five measured image dimensions", len(outputs) == 5 and
                    {r.get("fileName") for r in outputs} == names)
        for image in outputs:
            name = image.get("fileName", "")
            lla = name == "lla_geobasemap.png"
            width, height = (1000, 1000) if name == "sky_plot.png" else (1400, 950)
            audit.check(prefix+" export stage "+name,
                        name in names and canonical(image.get("path", "")) == canonical(output/name) and
                        image.get("width") == width and image.get("height") == height and
                        image.get("renderStage") == "offline_navigation" and
                        image.get("subsequentlyReplacedBySatelliteMap") is lla)
            if not lla:
                info = png_header(output/name)
                audit.check(prefix+" final dimensions "+name, bool(info) and
                            info["width"] == width and info["height"] == height)
        indices = prns(fig.get("retainedEpochIndices"))
        run_info = runs[(entry["sourceId"], key[1])]
        audit.check(prefix+" retained epoch bookkeeping", len(indices) == len(set(indices)) ==
                    fig.get("retainedFixes") and bool(indices) and indices[0] >= 1 and
                    (not run_info["complete"] or len(indices) <= run_info["nFixes"]) and
                    fig.get("removedJumpFixes", -1) >= 0)
        sky = fig.get("sky", {})
        slots = rows(sky.get("slotRecords"))
        audit.check(prefix+" sky uses original slot and epoch",
                    sky.get("mapping") == "PRN / az / el are paired by original channel slot and epoch" and
                    sky.get("projection") == "radius = 90*cos(elevation in degrees)" and
                    sky.get("missingFields") is False and bool(slots) and
                    len({r.get("PRN") for r in slots}) == len({r.get("slot") for r in slots}) == len(slots) and
                    all(r.get("PRN") in EXPECTED_PRNS and r.get("slot") in EXPECTED_PRNS and
                        r.get("finitePairedPoints", -1) == r.get("displayedPoints", 0)+r.get("outsideVisibleHemisphere", 0)
                        for r in slots) and
                    sky.get("omittedOutsideVisibleHemisphere") == sum(r.get("outsideVisibleHemisphere", 0) for r in slots))
        final_map, alias = output/"lla_satellite_dme.png", output/"lla_geobasemap.png"
        audit.check(prefix+" offline LLA preview replaced by final satellite map",
                    final_map.is_file() and alias.is_file() and hash_file(final_map) == hash_file(alias),
                    pending=not post_complete)


def validate_figure_postprocessing(audit,root,entries,runs):
    completion=read_json(root/"postprocessing_complete.json")
    complete=truth(completion.get("ok")) and completion.get("receiverRerun") is False
    audit.check("saved-only figure postprocessing complete",complete,pending=not bool(completion))
    all_runs_complete=all(r["complete"] for r in runs.values())
    pending=not complete
    acq_path=root/"analysis/acquisition_figure_verification.json"
    acq=rows(read_json(acq_path))
    expected={(e["sourceId"],mode) for e in entries for mode in ["PB","TF"]}
    actual={(r["sourceId"],r["method"]) for r in acq}
    audit.check("twelve acquisition figure audit records",len(acq)==12 and actual==expected,pending=pending)
    by_id={e["sourceId"]:e for e in entries}
    for r in acq:
        key=(r["sourceId"],r["method"]); prefix=f'{r["sourceId"]} {r["method"]} final acquisition figure'
        known=key in runs
        if not audit.check(prefix+" belongs to manifest",known): continue
        run=runs[key]; entry=by_id[key[0]]; run_dir=Path(entry["pbDir"] if key[1]=="PB" else entry["tfDir"])
        audit.check(prefix+" saved-only export",r.get("sourceMatUnchanged") is True and r.get("receiverRerun") is False)
        audit.check(prefix+" all 63 PRNs and correct detected set",prns(r.get("searchedPrns"))==EXPECTED_PRNS and
                    (not run["complete"] or prns(r.get("detectedPrns"))==run["acquiredPrns"]))
        audit.check(prefix+" expected source path",canonical(r["sourceMat"])==canonical(run_dir/"ui_results.mat"))
        audit.check(prefix+" expected output path",canonical(r["png"])==canonical(run_dir/"figures/AcqResult/acquisition_metrics.png"))
        image=png_header(Path(r["png"]))
        audit.check(prefix+" exact 1800x1000 PNG",bool(image) and image["width"]==r.get("widthPixels")==1800 and
                    image["height"]==r.get("heightPixels")==1000)
        audit.check(prefix+" readable PRN labels",r.get("prnLabelRotationDeg")==90 and r.get("axisFontPt",0)>=10)
    trk_path=root/"analysis/tracking_figure_verification.json"
    trk=read_json(trk_path); records=rows(trk.get("records",[]))
    audit.check("tracking figure audit exists",bool(trk),pending=pending)
    if not trk: return
    audit.check("tracking figure export preserved source MATs",trk.get("allSourceMatsUnchanged") is True and
                trk.get("receiverRerun") is False and trk.get("originalPlotHelperUnmodified") is True)
    expected_tracks={(sid,mode,p) for (sid,mode),r in runs.items() if r["complete"] for p in r["acquiredPrns"]}
    actual_tracks={(r["sourceId"],r["method"],int(r["PRN"])) for r in records}
    audit.check("one corrected tracking figure per PB/TF satellite",all_runs_complete and
                actual_tracks==expected_tracks and len(records)==len(expected_tracks),pending=pending)
    audit.check("tracking nominal time and REACQ meanings documented","nominal" in trk.get("timeAxisNote","").lower() and
                "not valid measurements of zero error" in trk.get("reacqNote",""))
    for r in records:
        key=(r["sourceId"],r["method"]); prefix=f'{r["sourceId"]} {r["method"]} PRN{int(r["PRN"]):02d} corrected tracking figure'
        if key not in runs:
            audit.check(prefix+" belongs to manifest",False); continue
        units=(r.get("pllDiscrUnit")=="cycles" and r.get("pllDiscrFiltMeaning")=="carrier NCO (Hz)" and
               r.get("dllDiscrUnit")=="dimensionless normalized E-L/E+L" and
               r.get("dllDiscrFiltMeaning")=="code NCO (chips/s)")
        audit.check(prefix+" phase/discriminator and NCO units distinct",units)
        audit.check(prefix+" all state transitions and placeholders preserved",r.get("stateTransitionPointsPreserved") is True and
                    r.get("reacqPlaceholderValuesPreserved") is True)
        audit.check(prefix+" no receiver rerun or raw-statistic recomputation",r.get("receiverRerun") is False and
                    r.get("rawStatisticsRecomputed") is False)
        source=Path(r["sourceMat"])
        entry=by_id[key[0]]; run_dir=Path(entry["pbDir"] if key[1]=="PB" else entry["tfDir"])
        match=re.fullmatch(r"Trk_Prn_(\d+)_final\.mat",source.name)
        audit.check(prefix+" source and output paths match PRN",canonical(source.parent)==canonical(run_dir/"temp") and
                    bool(match) and int(match.group(1))==int(r["PRN"]) and
                    canonical(r["png"])==canonical(run_dir/"figures/trkResult"/f'PRN_{int(r["PRN"]):02d}_tracking.png'))
        audit.check(prefix+" source size matches unchanged audit",r.get("sourceMatUnchanged") is True and
                    source.is_file() and source.stat().st_size==r.get("sourceBytes"))
        count=r.get("plottedNominalEpochs",0); step=r.get("epochSeconds",0); span=r.get("nominalTimeRangeSeconds",[])
        audit.check(prefix+" nominal row-index time range",count>0 and step>0 and len(span)==2 and close(span[0],0) and
                    close(span[1],max(0,count-1)*step))
        image=png_header(Path(r["png"]))
        audit.check(prefix+" PNG matches audit dimensions",bool(image) and image["width"]==r.get("widthPixels") and
                    image["height"]==r.get("heightPixels"))


def validate_final_source_provenance(audit,root,project):
    path=root/"final_source_manifest.json"
    final=read_json(path)
    if not audit.check("final source provenance manifest exists",bool(final),pending=True):
        return
    numerical=final.get("numericalSources",{})
    audit.check("final source provenance complete",final.get("ok") is True and final.get("state")=="complete")
    audit.check("final 69 numerical sources match PB and startup",numerical.get("sourceCount")==69 and
                numerical.get("sameSourceSet") is True and numerical.get("matchPB") is True and
                numerical.get("matchStartup") is True and len(numerical.get("files",{}))==69)
    startup=final.get("startupEvidence",{})
    startup_path=root/"source_manifest.json"
    audit.check("startup manifest preserved in final provenance",startup.get("preservedWithoutModification") is True and
                startup_path.is_file() and sha_match(startup_path,startup.get("sha256")))
    batch=final.get("batchSources",{})
    current_batch={p.relative_to(project).as_posix() for p in (project/"batch").iterdir()
                   if p.is_file() and "data1020" in p.name.lower() and p.suffix.lower() in (".m",".py",".ps1")}
    recorded_batch={name.replace("\\","/") for name in batch.get("files",{})}
    audit.check("final batch provenance includes current MATLAB Python PowerShell sources",current_batch<=recorded_batch,
                {"missingCurrentScripts":sorted(current_batch-recorded_batch)})
    audit.check("final provenance includes automatic finishing script",
                "batch/finish_data1020_tf_queue.ps1" in recorded_batch)
    mismatches=[]; bad_paths=[]
    for group,files in [("numerical",numerical.get("files",{})),("batch",batch.get("files",{}))]:
        for name,digest in files.items():
            source=(project/name.replace("\\","/")).resolve()
            if not source.is_relative_to(project):
                bad_paths.append(name); continue
            if not source.is_file() or not sha_match(source,digest):
                mismatches.append({"group":group,"path":name})
    audit.check("final provenance working-tree source bytes reproduce",not mismatches and not bad_paths,
                {"changedOrMissingSources":mismatches,"outsideProjectPaths":bad_paths,
                 "scope":"Source file SHA256 only; generated result HTML/JSON/MAT, timestamps, git status, and worktree cleanliness are not compared."})
    post=batch.get("postprocessingFiles",{})
    audit.check("final postprocessing hashes agree with batch hashes",bool(post) and
                all(batch.get("files",{}).get(name)==digest for name,digest in post.items()))


def sha_match(path,expected):
    return isinstance(expected,str) and hash_file(path)==expected.lower()


def validate_comparison(audit,root,entries,runs):
    path=root/"comparison/comparison_report.json"
    report=read_json(path)
    if not audit.check("six-pair comparison report exists",bool(report),pending=True):
        return
    experiments=rows(report.get("experiments"))
    by_id={e["summary"]["sourceId"]:e["summary"] for e in experiments}
    audit.check("six comparison groups",set(by_id)==EXPECTED_IDS and len(experiments)==6)
    summary_csv=read_csv(root/"comparison/comparison_summary.csv")
    audit.check("six comparison CSV rows",len(summary_csv)==6 and {r["sourceId"] for r in summary_csv}==EXPECTED_IDS)
    for e in entries:
        source_id=e["sourceId"]; summary=by_id.get(source_id,{})
        if not summary:
            continue
        for mode in ["PB","TF"]:
            run=runs[(source_id,mode)]; tag=mode.lower()
            if run["complete"]:
                audit.check(f'{e["experimentNumber"]:02d} {mode} comparison matches final output',
                    prns(summary.get(tag+"AcquiredPrns"))==run["acquiredPrns"] and
                    summary.get(tag+"Acquired")==run["nAcquired"] and
                    summary.get(tag+"FiniteNavigationEpochs")==run["nFixes"] and
                    summary.get(tag+"FullLengthRecorded")==run["fullLength"])
    verification_path=root/"comparison/comparison_validation.json"
    verification=read_json(verification_path)
    audit.check("independent comparison interval and CSV audit",bool(verification) and truth(verification.get("ok")),
                {"path":str(verification_path)},pending=not bool(verification))

    definitions=report.get("definitions",{})
    audit.check("comparison distinguishes availability from accuracy","not absolute positioning accuracy" in definitions.get("navigationAccuracy",""))
    audit.check("comparison distinguishes common from independent intervals","common" in definitions.get("commonQualify","").lower())


class Links(HTMLParser):
    def __init__(self): super().__init__(); self.urls=[]; self.ids=set()
    def handle_starttag(self,tag,attrs):
        for key,value in attrs:
            if key in ("href","src") and value: self.urls.append(value)
            if key=="id": self.ids.add(value)


def validate_html(audit,root):
    pages=[root/"index.html",root/"comparison_brief.html",root/"comparison/comparison_brief.html"]
    checked=0
    for page in pages:
        if not audit.required(page,"HTML page "+str(page.relative_to(root)),pending=True): continue
        text=page.read_text(encoding="utf-8"); parser=Links(); parser.feed(text)
        missing=[]; absolute=[]; anchors=[]
        for url in parser.urls:
            if re.match(r"^[A-Za-z]:[/\\]",url) or url.lower().startswith("file:"):
                absolute.append(url); continue
            u=urlsplit(url)
            if u.scheme: continue
            if u.path:
                checked+=1
                if not (page.parent/unquote(u.path)).exists(): missing.append(url)
            elif u.fragment and unquote(u.fragment) not in parser.ids:
                anchors.append(url)
        audit.check("relative links "+page.name,not missing and not absolute and not anchors,
                    {"missing":missing,"absoluteLocalPaths":absolute,"missingAnchors":anchors})
        if page.parent==root:
            audit.check("weak station caveat "+page.name,"弱候选" in text and "频响" in text and "官庄" in text)
            audit.check("navigation accuracy caveat "+page.name,"有限定位" in text and "精度" in text and
                        ("未提供" in text or "不等于" in text or "不能" in text))
            if (root/"analysis/tracking_figure_verification.json").exists():
                audit.check("corrected plot units and nominal time explained "+page.name,
                            all(term in text for term in ["名义跟踪时间","absoluteSample / samplingFreq","cycles","chips/s","REACQ"]))
    return checked


def validate_recovery(audit, root, manifest, runs):
    """Check recovery provenance without loading MAT arrays or rehashing big finals."""
    recovery = read_json(root/"recovery_audit.json")
    if not audit.check("crash-recovery audit exists", bool(recovery)):
        return
    entries = manifest["entries"]
    entry = next(e for e in entries if e["experimentNumber"] == 5)
    finals = rows(recovery.get("preservedFinals"))
    expected_prns = {24, 27, 28, 32, 33, 38, 39, 41}
    audit.check("eight pre-crash final identities recorded",
                len(finals) == 8 and {r.get("PRN") for r in finals} == expected_prns and
                all(canonical(r.get("path", "")) == canonical(Path(entry["tfDir"])/"temp"/
                    f'Trk_Prn_{r["PRN"]:02d}_final.mat') and
                    bool(re.fullmatch(r"[0-9a-f]{64}", str(r.get("sha256", ""))))
                    for r in finals))
    audit.check("recovery restarted complete PRN25 and PRN30 channels without splicing",
                recovery.get("interruptedExperiment") == 5 and
                recovery.get("completedBeforeCrash") == [1, 2, 3, 4] and
                recovery.get("restartWholeChannels") == [25, 30] and
                recovery.get("loopStateCheckpointAvailable") is False and
                recovery.get("splicingOldAndRestartedTracking") is False)
    execution = recovery.get("execution", {})
    audit.check("recovery execution is serial and single thread",
                execution.get("matlabVersion") == "R2024b" and
                execution.get("singleComputationalThread") is True and
                execution.get("oneProcessPerStage") is True and
                execution.get("parallelPool") is False and
                execution.get("useParfor") is False and
                execution.get("useParallelAcquisition") is False and
                execution.get("parMaxWorkers") == 1)
    all_tf_complete = all(runs[(e["sourceId"], "TF")]["complete"] for e in entries)
    audit.check("recovery finalized with eight unchanged final hashes and all six TF runs",
                recovery.get("recoveryComplete") is True and
                recovery.get("preservedFinalsUnchanged") is True and
                recovery.get("changedOrMissingFinals") == [] and
                recovery.get("completedTfExperiments") == list(range(1, 7)) and
                bool(recovery.get("verifiedUtc")), pending=not all_tf_complete)
    chunk = verify_replayed_chunk(root, manifest)
    audit.check("PRN25 chunk001 evidence identity and source hashes",
                chunk["ok"] and chunk["sourceHashesVerified"], chunk)
    recorded_chunk = recovery.get("replayedChunkVerification")
    audit.check("recovery audit links the verified PRN25 chunk001 evidence",
                recorded_chunk == chunk, pending=not all_tf_complete and not recorded_chunk)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root",type=Path); parser.add_argument("--allow-pending",action="store_true")
    args=parser.parse_args(); root=args.root.resolve(); project=Path(__file__).resolve().parents[1]
    audit=Audit(); manifest=read_json(root/"manifest.json"); entries=manifest.get("entries",[])
    if not entries: raise SystemExit("Valid manifest.json is required")
    audit.check("six requested experiments excluding HUR",len(entries)==6 and {e["sourceId"] for e in entries}==EXPECTED_IDS)
    audit.check("chronological experiment numbering",[e["experimentNumber"] for e in entries]==list(range(1,7)) and
                [e["utcStart"] for e in entries]==sorted(e["utcStart"] for e in entries))
    audit.check("N/E coordinate convention recorded","N=latitude" in manifest.get("stationCoordinateConvention",""))
    baseline_cases={r["id"]:r for r in rows(read_json(Path(manifest["baselineRoot"])/"cases.json"))}
    snapshot_path=root/"source_input_snapshot.json"; saved=read_json(snapshot_path)
    prior={r["sourceId"]:r for r in saved.get("inputs",[])}; current=[]; runs={}
    for e in entries:
        source=Path(e["sourceFile"]); prefix=f'{e["experimentNumber"]:02d} {e["sourceId"]}'
        if audit.required(source,prefix+" source IQ exists"):
            fingerprint=input_fingerprint(source); fingerprint["sourceId"]=e["sourceId"]; current.append(fingerprint)
            baseline=baseline_cases.get(e["sourceId"],{})
            expected=round(baseline.get("durationSeconds",0)*e["samplingFreq"]*4)
            audit.check(prefix+" source IQ size matches PB input",fingerprint["sizeBytes"]==expected,
                        {"actualBytes":fingerprint["sizeBytes"],"recordedExpectedBytes":expected})
            if e["sourceId"] in prior:
                old=prior[e["sourceId"]]
                audit.check(prefix+" source IQ unchanged since first audit",all(fingerprint[k]==old[k] for k in ["sizeBytes","mtimeNs","sampleHashes"]))
        expected_name=f'{e["experimentNumber"]:02d}-{e["stationName"]}{"候选" if e.get("stationMatchIsWeak") else ""}-{e["sourceId"]}'
        audit.check(prefix+" output folder naming",Path(e["pbDir"]).name==expected_name and Path(e["tfDir"]).name==expected_name+"-TF")
        for mode in ["PB","TF"]: runs[(e["sourceId"],mode)]=validate_run(audit,e,mode)
        pb,tf=runs[(e["sourceId"],"PB")],runs[(e["sourceId"],"TF")]
        if pb["complete"] and tf["complete"]:
            a,b=pb["settings"],tf["settings"]
            changed=sorted(k for k in set(a)|set(b) if a.get(k)!=b.get(k))
            forbidden=sorted(set(changed)-ALLOWED_SETTING_CHANGES)
            audit.check(prefix+" independent JSON condition equality",not forbidden,{"changedFields":changed,"forbiddenFields":forbidden})
    if not saved:
        snapshot={"capturedUtc":dt.datetime.now(dt.timezone.utc).isoformat(),"inputs":current,
                  "scope":"Size, last-write timestamp, and SHA256 of first/middle/last 64KiB. Not a full-content checksum and not evidence predating this snapshot."}
        snapshot_path.write_text(json.dumps(snapshot,ensure_ascii=False,indent=2),encoding="utf-8")
    source=read_json(root/"source_manifest.json"); mismatches=[]
    for name,expected in source.get("files",{}).items():
        p=project/name
        if not p.is_file() or hash_file(p)!=expected: mismatches.append(name)
    audit.check("numerical source hash manifest intact",bool(source.get("files")) and not mismatches,mismatches)
    audit.check("numerical receiver baseline consistency recorded",truth(source.get("numericalReceiverMatchesPB")))
    for r in rows(read_json(root/"removed_hur_results.json")):
        audit.check("excluded HUR result removed "+Path(r["path"]).name,not Path(r["path"]).exists() and r.get("rawInputDeleted") is False)
    hur=baseline_cases.get("HUR",{}).get("file")
    audit.check("excluded raw HUR retained as declared",bool(hur) and Path(hur).is_file() and manifest.get("rawRecordingDeletion") is False)
    spectrum=read_json(root/"analysis/fft_station_analysis.json")
    spectral_rows=rows(spectrum.get("entries")); audit.check("six raw-IQ spectral analyses",{r["sourceId"] for r in spectral_rows}==EXPECTED_IDS)
    for e in entries:
        a=root/"analysis"/f'{e["experimentNumber"]:02d}_{e["sourceId"]}'
        for name in ["raw_fft_fullband.png","station_band_zoom.png","spectral_station_evidence.json","welch_spectrum.csv","window_diagnostics.csv","spectral_data.mat"]:
            audit.required(a/name,f'{e["sourceId"]} FFT '+name)
        audit.required(Path(e["stationEvidencePath"]),e["sourceId"]+" station evidence manifest link")
    weak=next(e for e in entries if e["sourceId"]=="beiqijiatai")
    audit.check("weak Guanzhuang association not overstated",weak.get("stationMatchIsWeak") is True and weak.get("stationId")=="guanzhuang" and
                float(weak.get("stationEvidence",{}).get("meanBandContrastDb",99))<1.5)
    completion=read_json(root/"tf_full_completion.json")
    audit.check("full TF queue completion recorded",bool(completion) and prns(completion.get("indices"))==list(range(1,7)),pending=not bool(completion))
    validate_maps(audit,root,entries); validate_navigation_figures(audit,root,entries,runs)
    validate_figure_postprocessing(audit,root,entries,runs)
    validate_final_source_provenance(audit,root,project)
    validate_comparison(audit,root,entries,runs)
    validate_recovery(audit,root,manifest,runs)
    link_count=validate_html(audit,root)
    failed=[r for r in audit.checks if r["status"]=="failed"]; pending=[r for r in audit.checks if r["status"]=="pending"]
    result={"generatedUtc":dt.datetime.now(dt.timezone.utc).isoformat(),"ok":not failed and not pending,
            "state":"failed" if failed else ("pending" if pending else "complete"),
            "experimentCount":len(entries),"pbCompleted":sum(runs[(e["sourceId"],"PB")]["complete"] for e in entries),
            "tfCompleted":sum(runs[(e["sourceId"],"TF")]["complete"] for e in entries),
            "passedChecks":sum(r["status"]=="passed" for r in audit.checks),"failedChecks":failed,"pendingChecks":pending,
            "checkedLocalLinks":link_count,"sourceInputFingerprintScope":"first/middle/last 64KiB, size and mtime only; no full raw-file hash",
            "validatorSha256":hash_file(__file__),"checks":audit.checks}
    (root/"final_validation.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps({k:v for k,v in result.items() if k not in ["checks","sourceInputFingerprintScope"]},ensure_ascii=True))
    if failed or (pending and not args.allow_pending): raise SystemExit(1)


if __name__=="__main__": main()
