/**
 * B2a PVT track on Baidu Map JSAPI 4.0
 *
 * GNSS = WGS84; Baidu tiles = BD-09.
 * Prefer official BMap.Convertor (1→5); fall back to offline transform
 * if Convertor fails (common under file:// or network/AK issues).
 *
 * Docs: https://lbsyun.baidu.com/docs/jsapi?title=jsapi4/guide/concept/coord
 */
(function () {
  'use strict';

  var statusEl = document.getElementById('status');
  function setStatus(html, isErr) {
    if (!statusEl) return;
    statusEl.innerHTML = html;
    statusEl.className = isErr ? 'err' : 'muted';
  }

  function loadTrack() {
    var el = document.getElementById('b2a-track-data');
    if (el && el.textContent && el.textContent.trim() && el.textContent.indexOf('{{') < 0) {
      return Promise.resolve(JSON.parse(el.textContent));
    }
    var url = window.B2A_TRACK_URL || 'track.json';
    return fetch(url, { cache: 'no-store' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status + ' loading ' + url);
      return r.json();
    });
  }

  // ---- Offline WGS84 -> GCJ-02 -> BD-09 (China offset; no network) ----
  var PI = Math.PI;
  var A = 6378245.0;
  var EE = 0.00669342162296594323;

  function outOfChina(lng, lat) {
    return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
  }
  function transformLat(lng, lat) {
    var ret = -100.0 + 2.0 * lng + 3.0 * lat + 0.2 * lat * lat +
      0.1 * lng * lat + 0.2 * Math.sqrt(Math.abs(lng));
    ret += (20.0 * Math.sin(6.0 * lng * PI) + 20.0 * Math.sin(2.0 * lng * PI)) * 2.0 / 3.0;
    ret += (20.0 * Math.sin(lat * PI) + 40.0 * Math.sin(lat / 3.0 * PI)) * 2.0 / 3.0;
    ret += (160.0 * Math.sin(lat / 12.0 * PI) + 320 * Math.sin(lat * PI / 30.0)) * 2.0 / 3.0;
    return ret;
  }
  function transformLng(lng, lat) {
    var ret = 300.0 + lng + 2.0 * lat + 0.1 * lng * lng +
      0.1 * lng * lat + 0.1 * Math.sqrt(Math.abs(lng));
    ret += (20.0 * Math.sin(6.0 * lng * PI) + 20.0 * Math.sin(2.0 * lng * PI)) * 2.0 / 3.0;
    ret += (20.0 * Math.sin(lng * PI) + 40.0 * Math.sin(lng / 3.0 * PI)) * 2.0 / 3.0;
    ret += (150.0 * Math.sin(lng / 12.0 * PI) + 300.0 * Math.sin(lng / 30.0 * PI)) * 2.0 / 3.0;
    return ret;
  }
  function wgs84ToGcj02(lng, lat) {
    if (outOfChina(lng, lat)) return [lng, lat];
    var dLat = transformLat(lng - 105.0, lat - 35.0);
    var dLng = transformLng(lng - 105.0, lat - 35.0);
    var radLat = lat / 180.0 * PI;
    var magic = Math.sin(radLat);
    magic = 1 - EE * magic * magic;
    var sqrtMagic = Math.sqrt(magic);
    dLat = (dLat * 180.0) / ((A * (1 - EE)) / (magic * sqrtMagic) * PI);
    dLng = (dLng * 180.0) / (A / sqrtMagic * Math.cos(radLat) * PI);
    return [lng + dLng, lat + dLat];
  }
  function gcj02ToBd09(lng, lat) {
    var z = Math.sqrt(lng * lng + lat * lat) + 0.00002 * Math.sin(lat * PI * 3000.0 / 180.0);
    var theta = Math.atan2(lat, lng) + 0.000003 * Math.cos(lng * PI * 3000.0 / 180.0);
    return [z * Math.cos(theta) + 0.0065, z * Math.sin(theta) + 0.006];
  }
  function offlineWgs84ToBd09(pointsWgs) {
    return pointsWgs.map(function (p) {
      var g = wgs84ToGcj02(p.lng, p.lat);
      var b = gcj02ToBd09(g[0], g[1]);
      return new BMap.Point(b[0], b[1]);
    });
  }

  /** Official Convertor batch WGS84(1) -> BD09(5); max 10 pts/request. */
  function convertorWgs84ToBd09(pointsWgs) {
    return new Promise(function (resolve, reject) {
      if (typeof BMap.Convertor !== 'function') {
        reject(new Error('BMap.Convertor not available'));
        return;
      }
      if (!pointsWgs.length) {
        resolve([]);
        return;
      }
      var convertor = new BMap.Convertor();
      var batchSize = 10;
      var out = new Array(pointsWgs.length);
      var next = 0;
      var pending = 0;
      var failed = false;
      var timer = setTimeout(function () {
        if (!failed) {
          failed = true;
          reject(new Error('Convertor timeout'));
        }
      }, 12000);

      function finishOk(pts) {
        clearTimeout(timer);
        resolve(pts);
      }
      function finishErr(err) {
        clearTimeout(timer);
        reject(err);
      }

      function pump() {
        if (failed) return;
        if (next >= pointsWgs.length && pending === 0) {
          finishOk(out);
          return;
        }
        while (next < pointsWgs.length && pending < 2) {
          var start = next;
          var end = Math.min(start + batchSize, pointsWgs.length);
          next = end;
          pending++;
          (function (s, e) {
            var chunk = pointsWgs.slice(s, e);
            try {
              convertor.translate(chunk, 1, 5, function (data) {
                pending--;
                if (failed) return;
                if (!data || (data.status !== 0 && data.status !== '0' && data.status !== undefined)) {
                  failed = true;
                  finishErr(new Error('Convertor status=' + (data && data.status)));
                  return;
                }
                var pts = data.points || [];
                for (var i = 0; i < pts.length; i++) out[s + i] = pts[i];
                for (var j = pts.length; j < e - s; j++) out[s + j] = chunk[j];
                pump();
              });
            } catch (ex) {
              failed = true;
              finishErr(ex);
            }
          })(start, end);
        }
      }
      pump();
    });
  }

  function toBd09(pointsWgs) {
    return convertorWgs84ToBd09(pointsWgs).then(function (pts) {
      return { points: pts, how: 'BMap.Convertor 1→5' };
    }).catch(function (err) {
      console.warn('Convertor failed, offline BD-09:', err);
      return { points: offlineWgs84ToBd09(pointsWgs), how: 'offline WGS84→GCJ02→BD09 (fallback)' };
    });
  }

  function drawTrack(bdPoints, meta, how) {
    // Drop undefined holes if convertor partially failed
    bdPoints = bdPoints.filter(function (p) {
      return p && typeof p.lng === 'number' && typeof p.lat === 'number' &&
        isFinite(p.lng) && isFinite(p.lat);
    });
    if (!bdPoints.length) throw new Error('no valid BD-09 points after convert');

    var center = bdPoints[Math.floor(bdPoints.length / 2)] || bdPoints[0];
    var map = new BMap.Map('map');
    map.centerAndZoom(center, 16);
    map.enableScrollWheelZoom(true);
    map.enableDragging(true);
    map.enableDoubleClickZoom(true);

    try {
      if (typeof BMap.NavigationControl === 'function') {
        map.addControl(new BMap.NavigationControl());
      }
      if (typeof BMap.ScaleControl === 'function') {
        map.addControl(new BMap.ScaleControl());
      }
      if (typeof BMap.MapTypeControl === 'function') {
        map.addControl(new BMap.MapTypeControl());
      }
    } catch (e) {
      console.warn('controls:', e);
    }

    // Force a known basemap type if API exposes it
    try {
      if (typeof BMAP_NORMAL_MAP !== 'undefined') {
        map.setMapType(BMAP_NORMAL_MAP);
      }
    } catch (e2) { /* ignore */ }

    var polyline = new BMap.Polyline(bdPoints, {
      strokeColor: '#1a73e8',
      strokeWeight: 5,
      strokeOpacity: 0.9,
      strokeStyle: 'solid',
      enableClicking: false
    });
    map.addOverlay(polyline);

    map.addOverlay(new BMap.Marker(bdPoints[0]));
    map.addOverlay(new BMap.Marker(bdPoints[bdPoints.length - 1]));

    if (typeof map.setViewport === 'function') {
      try {
        map.setViewport(bdPoints, { margins: [60, 40, 40, 40] });
      } catch (e3) {
        map.centerAndZoom(center, 16);
      }
    }

    // Nudge redraw (helps after container was 0-size under some hosts)
    setTimeout(function () {
      try {
        if (typeof map.checkResize === 'function') map.checkResize();
        map.centerAndZoom(map.getCenter(), map.getZoom());
      } catch (e4) { /* ignore */ }
    }, 200);

    var proto = (location.protocol || '').toLowerCase();
    var warn = '';
    if (proto === 'file:') {
      warn = '<br/><span class="err">提示: 当前是 file:// 打开。百度底图常被拦，请用 http://127.0.0.1 起本地服务（MATLAB launch 会自动起）。</span>';
    }

    setStatus(
      '点数: <b>' + bdPoints.length + '</b><br/>' +
      '坐标: WGS84 → BD-09 via <b>' + how + '</b><br/>' +
      '均值 WGS84: ' + meta.meanLat.toFixed(6) + ', ' + meta.meanLon.toFixed(6) + '<br/>' +
      '协议: ' + proto + ' · 若只有线/点、无底图：查 AK 是否开 JSAPI、Referer 白名单是否含 localhost' +
      warn
    );
  }

  function main() {
    if (typeof BMap === 'undefined') {
      setStatus(
        'BMap 未加载。<br/>' +
        '1) AK 是否启用「JavaScript API」<br/>' +
        '2) 浏览器端 AK 的 Referer 白名单是否含 <code>*</code> 或 <code>127.0.0.1</code><br/>' +
        '3) 不要用 file:// 双击打开，请用本地 http 服务',
        true
      );
      return;
    }

    var mapBox = document.getElementById('map');
    if (!mapBox || mapBox.clientHeight < 10) {
      setStatus('地图容器高度为 0，请检查 CSS (#map height:100%)', true);
    }

    loadTrack()
      .then(function (track) {
        var raw = track.points || [];
        if (!raw.length) throw new Error('track has no points');
        var wgs = raw.map(function (p) {
          return new BMap.Point(Number(p.lng), Number(p.lat));
        });
        setStatus('坐标转换中…');
        return toBd09(wgs).then(function (res) {
          drawTrack(res.points, {
            meanLat: track.meanLat || raw[0].lat,
            meanLon: track.meanLon || raw[0].lng
          }, res.how);
        });
      })
      .catch(function (err) {
        console.error(err);
        setStatus('失败: ' + (err && err.message ? err.message : err), true);
      });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
