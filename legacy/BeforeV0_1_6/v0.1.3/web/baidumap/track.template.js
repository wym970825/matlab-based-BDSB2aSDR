/**
 * B2a PVT track on Baidu Map JSAPI 4.0
 *
 * GNSS fixes are WGS84. Baidu Maps uses BD-09.
 * Official convert: BMap.Convertor.translate(points, from, to, callback)
 *   1 = WGS84, 5 = BD-09
 * Docs: https://lbsyun.baidu.com/docs/jsapi?title=jsapi4/guide/concept/coord
 *
 * Convertor accepts up to 10 points per request — we batch.
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
    // Prefer embedded JSON (works under file://); fallback to track.json via fetch
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

  /** Batch WGS84 -> BD-09 via official Convertor (from=1, to=5). */
  function wgs84ToBd09(pointsWgs) {
    return new Promise(function (resolve, reject) {
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

      function pump() {
        if (failed) return;
        if (next >= pointsWgs.length && pending === 0) {
          resolve(out);
          return;
        }
        while (next < pointsWgs.length && pending < 3) {
          var start = next;
          var end = Math.min(start + batchSize, pointsWgs.length);
          next = end;
          pending++;
          (function (s, e) {
            var chunk = pointsWgs.slice(s, e);
            convertor.translate(chunk, 1, 5, function (data) {
              pending--;
              if (failed) return;
              // status === 0 success (JSAPI 3/4)
              if (!data || (data.status !== 0 && data.status !== undefined && data.status !== '0')) {
                failed = true;
                reject(new Error('Convertor failed status=' + (data && data.status)));
                return;
              }
              var pts = data.points || [];
              for (var i = 0; i < pts.length; i++) {
                out[s + i] = pts[i];
              }
              // if API returned fewer points, keep residual as original (should not happen)
              for (var j = pts.length; j < e - s; j++) {
                out[s + j] = chunk[j];
              }
              pump();
            });
          })(start, end);
        }
      }
      pump();
    });
  }

  function drawTrack(bdPoints, meta) {
    var center = bdPoints[Math.floor(bdPoints.length / 2)] || bdPoints[0];
    var map = new BMap.Map('map', {
      center: center,
      zoom: 16
    });
    map.enableScrollWheelZoom(true);
    if (typeof BMap.NavigationControl === 'function') {
      map.addControl(new BMap.NavigationControl());
    }
    if (typeof BMap.ScaleControl === 'function') {
      map.addControl(new BMap.ScaleControl());
    }

    var polyline = new BMap.Polyline(bdPoints, {
      strokeColor: '#1a73e8',
      strokeWeight: 4,
      strokeOpacity: 0.85,
      strokeStyle: 'solid'
    });
    map.addOverlay(polyline);

    var startMk = new BMap.Marker(bdPoints[0]);
    map.addOverlay(startMk);
    var endMk = new BMap.Marker(bdPoints[bdPoints.length - 1]);
    map.addOverlay(endMk);

    if (typeof map.setViewport === 'function') {
      map.setViewport(bdPoints);
    } else {
      map.centerAndZoom(center, 16);
    }

    setStatus(
      '点数: <b>' + bdPoints.length + '</b><br/>' +
      '源坐标: WGS84 → 显示: BD-09 (Convertor 1→5)<br/>' +
      '均值 WGS84: ' + meta.meanLat.toFixed(6) + ', ' + meta.meanLon.toFixed(6) + '<br/>' +
      '<span class="muted">绿点=起点 · 默认标=终点 · 蓝线=轨迹</span>'
    );
  }

  function main() {
    if (typeof BMap === 'undefined') {
      setStatus('BMap 未加载：检查 AK 是否开启 JSAPI 4.0，或网络/域名白名单。', true);
      return;
    }
    loadTrack()
      .then(function (track) {
        var raw = track.points || [];
        if (!raw.length) throw new Error('track.json has no points');
        var wgs = raw.map(function (p) {
          return new BMap.Point(p.lng, p.lat);
        });
        setStatus('坐标转换中 (WGS84→BD-09)…');
        return wgs84ToBd09(wgs).then(function (bd) {
          drawTrack(bd, {
            meanLat: track.meanLat || raw[0].lat,
            meanLon: track.meanLon || raw[0].lng
          });
        });
      })
      .catch(function (err) {
        console.error(err);
        setStatus('加载/转换失败: ' + (err && err.message ? err.message : err), true);
      });
  }

  // Script tag load is sync; run after DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
