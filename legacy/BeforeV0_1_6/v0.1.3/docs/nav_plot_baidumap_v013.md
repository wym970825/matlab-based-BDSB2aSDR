# v0.1.3 Post-PVT plots + Baidu Map UI

## MATLAB figures (`plotNavPost`)

| Figure | Content |
|--------|---------|
| ENU variations | ΔE/ΔN/ΔU vs time (ref = mean or `truePosition`) |
| Sky plot | `skyPlot` az/el + PRN (SoftGNSS) |
| LLA scatter | Mapping Toolbox `geoshow` when licensed; else plain `plot(lon,lat)` |

Called from `run_B2a` after navigation when `doPlot=true`.

## Baidu Map web UI

- Templates: `web/baidumap/`
- Export: `launchBaiduMapTrack` → `results/.../index.html` + embedded `track.json`
- AK: `config/BaidumapKey.txt` (**gitignored**)
- API: JSAPI **4.0** — https://lbsyun.baidu.com/docs/jsapi?title=jsapi4/index

### Coordinate offset (required in China)

| System | Role |
|--------|------|
| WGS84 | GNSS / `navSolutions.latitude/longitude` |
| BD-09 | Baidu Maps default |

Page uses official `BMap.Convertor.translate(points, 1, 5, cb)`  
(`1`=WGS84 → `5`=BD-09), batched ≤10 pts/request.  
Docs: https://lbsyun.baidu.com/docs/jsapi?title=jsapi4/guide/concept/coord

Display: basic 2D `Polyline` + start/end markers.
