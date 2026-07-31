# Baidu Map track UI (JSAPI 4.0)

## Features

- Time-ordered WGS84 track → BD-09 (Convertor / offline fallback)
- Polyline trajectory
- **CustomOverlay** start / end labels（起点 S / 终点 E）  
  Ref: https://lbs.baidu.com/jsapi/refdoc/v4/classes/BMap.CustomOverlay.html
- Time-heat scatter (CustomOverlay dots, subsampled)
- **Info panel bottom-right**: nPoints, duration, start/end, mean LLA/h, DOP

## Open

`launchBaiduMapTrack` starts a local HTTP server and opens:

```text
http://127.0.0.1:8765/index.html
```

Do **not** open `index.html` via `file://` — basemap tiles usually blank.

## AK

Put browser AK in `config/BaidumapKey.txt` (gitignored).  
Console: enable JavaScript API; Referer whitelist `127.0.0.1:*` or `*`.
