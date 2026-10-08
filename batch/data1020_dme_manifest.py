"""Read PB NMEA output and prepare chronological DATA1020 spectral metadata.

No receiver output or source IQ is changed. The user-supplied station coordinates
are interpreted by N/E hemisphere, since the original table headings were swapped.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import statistics
from pathlib import Path


STATIONS = [
    {"id": "Huairou", "name": "怀柔", "frequencyHz": 1170e6,
     "latitudeDeg": 40 + 19/60 + 45/3600,
     "longitudeDeg": 116 + 44/60 + 50/3600, "heightM": 62},
    {"id": "Zhangjiakou", "name": "张家口", "frequencyHz": 1173e6,
     "latitudeDeg": 40 + 43/60 + 45/3600,
     "longitudeDeg": 114 + 57/60 + 54/3600, "heightM": 735},
    {"id": "Guanzhuang", "name": "官庄", "frequencyHz": 1181e6,
     "latitudeDeg": 40 + 2/60 + 58/3600,
     "longitudeDeg": 116 + 44/60 + 2/3600, "heightM": 62},
]


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def latitude_longitude(value, hemisphere):
    value = float(value)
    angle = int(value / 100) + (value % 100) / 60
    return -angle if hemisphere in ("S", "W") else angle


def distance_km(lat1, lon1, lat2, lon2):
    a, b = math.radians(lat1), math.radians(lat2)
    h = math.sin((b-a)/2)**2 + math.cos(a)*math.cos(b)*math.sin(math.radians(lon2-lon1)/2)**2
    return 6371.0088 * 2 * math.asin(math.sqrt(min(1, max(0, h))))


def nmea_track(path):
    lines = [s.split(",") for s in Path(path).read_text(encoding="utf-8-sig").splitlines()]
    date_rows = [r for r in lines if r[0].endswith("ZDA") and len(r) >= 5]
    if not date_rows:
        raise ValueError(f"NMEA UTC date is missing: {path}")
    date = dt.date(int(date_rows[0][4]), int(date_rows[0][3]), int(date_rows[0][2]))
    result = []
    for r in lines:
        if not r[0].endswith("GGA") or len(r) < 10 or r[6] == "0" or not r[2] or not r[4]:
            continue
        clock = r[1]
        utc = dt.datetime.combine(date, dt.time(tzinfo=dt.timezone.utc)) + dt.timedelta(
            hours=int(clock[:2]), minutes=int(clock[2:4]), seconds=float(clock[4:]))
        result.append({"utc": utc.isoformat().replace("+00:00", "Z"),
                       "utcSecondsOfDay": (utc.hour*3600 + utc.minute*60 + utc.second + utc.microsecond/1e6),
                       "latitudeDeg": latitude_longitude(r[2], r[3]),
                       "longitudeDeg": latitude_longitude(r[4], r[5]),
                       "heightM": float(r[9]), "usedSatellites": int(r[7]),
                       "hdop": float(r[8])})
    if not result:
        raise ValueError(f"NMEA contains no valid position: {path}")
    # This mask is solely for station-distance diagnostics; raw coordinates remain
    # in the CSV. It is not a receiver measurement rejection or a truth criterion.
    lat_med = statistics.median(p["latitudeDeg"] for p in result)
    lon_med = statistics.median(p["longitudeDeg"] for p in result)
    for p in result:
        p["distanceDiagnosticAccepted"] = (abs(p["heightM"]) <= 1000 and
            distance_km(p["latitudeDeg"], p["longitudeDeg"], lat_med, lon_med) <= 20)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old_root", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    old_root, out = args.old_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cases = []
    for original_number, case in enumerate(read_json(old_root/"cases.json"), 1):
        if case["id"] == "HUR":
            continue
        run = old_root/f"full_{original_number:02d}_{case['id']}"
        config = read_json(case["configPath"])
        track = nmea_track(run/"pvt.nmea")
        good = [p for p in track if p["distanceDiagnosticAccepted"]]
        if not good:
            raise ValueError(f"No plausible coordinates for station distances: {run}")
        distances = []
        for s in STATIONS:
            d = [distance_km(p["latitudeDeg"], p["longitudeDeg"], s["latitudeDeg"], s["longitudeDeg"]) for p in good]
            distances.append({**s, "minimumDistanceKm": min(d), "medianDistanceKm": statistics.median(d),
                              "maximumDistanceKm": max(d), "positionCount": len(d)})
        track_file = out/f"track_{case['id']}.csv"
        with track_file.open("w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(track[0]))
            w.writeheader()
            w.writerows(track)
        cases.append({"id": case["id"], "originalCaseIndex": original_number,
                      "oldRunDir": str(run), "sourceFile": case["file"], "configPath": case["configPath"],
                      "durationSeconds": case["durationSeconds"], "requestedMs": case["requestedMs"],
                      "firstUtc": track[0]["utc"], "lastUtc": track[-1]["utc"],
                      "samplingFrequencyHz": config["samplingFreq"], "IFHz": case["IF"],
                      "centerFrequencyHz": 1176.45e6-case["IF"], "gainDb": case["gain"],
                      "staticPBAmplitude": case["thresholdAmplitude"], "trackCsv": str(track_file),
                      "validGgaCount": len(track), "distanceAcceptedGgaCount": len(good),
                      "stationCandidates": distances})
    cases.sort(key=lambda c: c["firstUtc"])
    for number, case in enumerate(cases, 1):
        case["experimentNumber"] = number
    manifest = {"coordinateConvention": "N=latitude, E=longitude; user table column headings swapped",
                "stationSource": "User-provided reference; transmitter identity is not independently verified",
                "distanceDiagnosticMask": "abs(GGA height)<=1000m and horizontal distance<=20km from median track point; raw rows preserved",
                "chronology": "first valid GGA UTC with ZDA date, not filename local time",
                "oldRoot": str(old_root), "outputDirectory": str(out), "stations": STATIONS, "cases": cases}
    (out/"dme_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    fields = ["experimentNumber", "id", "firstUtc", "lastUtc", "centerFrequencyHz", "gainDb", "durationSeconds"]
    with (out/"chronological_experiments.csv").open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(cases)
    print(json.dumps([{k: c[k] for k in fields} for c in cases], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
