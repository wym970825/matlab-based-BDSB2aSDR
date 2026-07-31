# Post-PVT display (MATLAB + Baidu Map)

## Master switch

| Setting | Default | Meaning |
|---------|---------|---------|
| `settings.plotNavPost` | **true** | MATLAB post-PVT figures (ENU / vel / DOP / sky / geo map) |
| `settings.plotBaiduMap` | **true** | Baidu Map web UI after `plotNavPost` |
| `settings.plotNavLegacy` | false | SoftGNSS `plotNavigation` combined figure |

Silent batch:

```matlab
settings.plotNavPost = false;   % no MATLAB figures
settings.plotBaiduMap = false;  % no browser UI
% or: plotNavPost(ns, settings, 'silent', true);
```

## Time-ordered track + jump filter

`navTrackTimeOrder(navSolutions, settings)`:

1. Drops non-finite lat/lon; keeps **epoch order**
2. Removes points that imply an ENU velocity jump: any of
   `|vE|`, `|vN|`, `|vU|` > `settings.navTrackMaxSpeedMps` (**default 500 m/s**)
   between consecutive samples (later point of the bad edge is discarded;
   iterated until clean)

Shared by MATLAB maps and Baidu export.

## MATLAB figures (`plotNavPost`)

1. **ENU displacement** ΔE/ΔN/ΔU vs time  
2. **ENU velocity** m/s (diff of ENU / Δt)  
3. **GDOP / HDOP / VDOP** (+ PDOP dashed if present)  
4. **Sky plot**  
5. **LLA map**: `geobasemap('streets-light')` + trajectory + **time-heat** scatter + **start (green ●) / end (red ■)**  
   Fallback: plain lon/lat scatter if Mapping Toolbox / geoaxes unavailable.

## Baidu Map JSAPI 4.0 (`launchBaiduMapTrack`)

- Templates: `web/baidumap/index.template.html`, `track.template.js`  
- [CustomOverlay](https://lbs.baidu.com/jsapi/refdoc/v4/classes/BMap.CustomOverlay.html) for:
  - start / end labels（起点 S / 终点 E）
  - time-heat track dots (subsampled, ≤~400)
- Polyline trajectory (time-ordered)
- **Info panel bottom-right**: nPoints, duration, start/end WGS84, mean LLA/h, median DOP, convert method
- WGS84 → BD-09: Convertor 1→5, offline fallback
- Open via `http://127.0.0.1:8765` (not `file://`)

## Smoke

```matlab
S = load('results/smoke/fullsky_pvt60_260731_063450/results.mat');
% re-nav if needed, then:
plotNavPost(navSolutions, settings, 'saveDir', 'results/smoke/navfigs_demo');
```
