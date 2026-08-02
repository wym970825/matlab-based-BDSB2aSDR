/* B2a Web UI — light research theme, full schema tabs, IF Probe gallery */
(function () {
  'use strict';

  const state = {
    schema: null,
    defaults: null,
    config: {},
    activeTab: null,
    jobId: null,
    pollTimer: null,
  };

  const $ = (id) => document.getElementById(id);

  function getByPath(obj, path) {
    const parts = path.split('.');
    let cur = obj;
    for (const p of parts) {
      if (cur == null || typeof cur !== 'object') return undefined;
      cur = cur[p];
    }
    return cur;
  }

  function setByPath(obj, path, value) {
    const parts = path.split('.');
    let cur = obj;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!cur[p] || typeof cur[p] !== 'object') cur[p] = {};
      cur = cur[p];
    }
    cur[parts[parts.length - 1]] = value;
  }

  function deepClone(o) {
    return JSON.parse(JSON.stringify(o));
  }

  function formatAcqList(v) {
    if (Array.isArray(v)) return v.join(',');
    if (v === null || v === undefined) return '';
    return String(v);
  }

  function formatVal(v) {
    if (v === null || v === undefined) return '';
    if (typeof v === 'number' && Number.isNaN(v)) return '';
    return v;
  }

  async function api(path, opts) {
    const r = await fetch(path, opts);
    const text = await r.text();
    let data;
    try { data = JSON.parse(text); } catch { data = { raw: text }; }
    if (!r.ok) throw new Error((data && data.error) || r.statusText || 'request failed');
    return data;
  }

  function setStatusPill(status) {
    const el = $('jobStatus');
    const cls = ['idle', 'running', 'done', 'failed'].includes(status) ? status : 'idle';
    el.innerHTML = `<span class="pill ${cls}">${status}</span>`;
    const bar = $('progressBar');
    bar.classList.toggle('indeterminate', status === 'running' || status === 'queued');
    if (status === 'done' || status === 'failed') bar.style.width = '100%';
    else if (status === 'idle') bar.style.width = '0%';
  }

  function appendLog(text, replace) {
    const pre = $('logView');
    if (replace) pre.textContent = text || '';
    else pre.textContent += text || '';
    pre.scrollTop = pre.scrollHeight;
  }

  function renderTabs() {
    const tabs = state.schema.tabs || [];
    const nav = $('tabs');
    const panels = $('tabPanels');
    nav.innerHTML = '';
    panels.innerHTML = '';
    tabs.forEach((tab, i) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'tab' + (i === 0 ? ' active' : '');
      btn.textContent = tab.label;
      btn.dataset.tab = tab.id;
      btn.addEventListener('click', () => activateTab(tab.id));
      nav.appendChild(btn);

      const panel = document.createElement('div');
      panel.className = 'tab-panel' + (i === 0 ? ' active' : '');
      panel.id = 'panel-' + tab.id;

      if (tab.kind === 'probe') {
        panel.innerHTML = `
          <p class="tab-desc">${tab.description || ''}</p>
          <div class="fields" id="fields-${tab.id}"></div>
          <div class="probe-box">
            <div class="probe-actions">
              <button type="button" class="btn probe" id="btnProbeInline">生成时域 / 频谱图</button>
              <span class="hint" style="align-self:center;color:var(--muted);font-size:0.8rem">
                使用「数据 / IF」中的文件与采样参数；仅读数绘图，不进入捕获
              </span>
            </div>
            <div id="probeGallery" class="probe-grid">
              <div class="probe-empty">尚未运行探针。请先确认 IF 路径，再点击上方按钮。</div>
            </div>
          </div>`;
      } else {
        panel.innerHTML = `
          <p class="tab-desc">${tab.description || ''}</p>
          <div class="fields" id="fields-${tab.id}"></div>`;
      }
      panels.appendChild(panel);
      renderFields(tab);
    });

    const bp = document.getElementById('btnProbeInline');
    if (bp) bp.addEventListener('click', startProbe);

    state.activeTab = tabs[0] && tabs[0].id;
  }

  function renderFields(tab) {
    const box = document.getElementById('fields-' + tab.id);
    if (!box) return;
    box.innerHTML = '';
    (tab.fields || []).forEach((f) => {
      const wrap = document.createElement('div');
      const isBool = f.type === 'bool';
      const full = f.full || f.path || f.key === 'filePath' || f.key === 'fileName'
        || f.key === 'acqSatelliteList' || f.key === 'nmea.fileName';
      wrap.className = 'field' + (isBool ? ' bool' : '') + (full ? ' full' : '');

      const id = 'f_' + f.key.replace(/\./g, '_');
      let val = getByPath(state.config, f.key);
      if (f.key === 'acqSatelliteList') val = formatAcqList(val);
      val = formatVal(val);

      if (isBool) {
        wrap.innerHTML = `
          <input type="checkbox" id="${id}" ${val ? 'checked' : ''} />
          <label for="${id}">${f.label}</label>`;
        wrap.querySelector('input').addEventListener('change', (e) => {
          setByPath(state.config, f.key, e.target.checked);
        });
      } else if (f.type === 'select') {
        const opts = (f.options || []).map((o) => {
          if (typeof o === 'object') {
            return `<option value="${o.v}" ${String(val) === String(o.v) ? 'selected' : ''}>${o.t}</option>`;
          }
          return `<option value="${o}" ${String(val) === String(o) ? 'selected' : ''}>${o}</option>`;
        }).join('');
        wrap.innerHTML = `
          <label for="${id}">${f.label}</label>
          <select id="${id}">${opts}</select>
          ${f.hint ? `<span class="hint">${f.hint}</span>` : ''}`;
        wrap.querySelector('select').addEventListener('change', (e) => {
          let v = e.target.value;
          if (/^-?\d+(\.\d+)?$/.test(v)) v = Number(v);
          setByPath(state.config, f.key, v);
        });
      } else if (f.type === 'number') {
        wrap.innerHTML = `
          <label for="${id}">${f.label}</label>
          <input type="number" id="${id}" value="${val}"
            ${f.min != null ? `min="${f.min}"` : ''}
            ${f.max != null ? `max="${f.max}"` : ''}
            ${f.step != null ? `step="${f.step}"` : 'step="any"'} />
          ${f.hint ? `<span class="hint">${f.hint}</span>` : ''}`;
        wrap.querySelector('input').addEventListener('change', (e) => {
          const v = e.target.value === '' ? null : Number(e.target.value);
          setByPath(state.config, f.key, v);
        });
      } else {
        const esc = String(val).replace(/"/g, '&quot;');
        wrap.innerHTML = `
          <label for="${id}">${f.label}</label>
          <input type="text" id="${id}" value="${esc}" />
          ${f.hint ? `<span class="hint">${f.hint}</span>` : ''}`;
        wrap.querySelector('input').addEventListener('change', (e) => {
          setByPath(state.config, f.key, e.target.value);
        });
      }
      box.appendChild(wrap);
    });
  }

  function activateTab(id) {
    state.activeTab = id;
    document.querySelectorAll('.tab').forEach((b) => {
      b.classList.toggle('active', b.dataset.tab === id);
    });
    document.querySelectorAll('.tab-panel').forEach((p) => {
      p.classList.toggle('active', p.id === 'panel-' + id);
    });
  }

  function collectConfig() {
    (state.schema.tabs || []).forEach((tab) => {
      (tab.fields || []).forEach((f) => {
        const id = 'f_' + f.key.replace(/\./g, '_');
        const el = document.getElementById(id);
        if (!el) return;
        if (f.type === 'bool') setByPath(state.config, f.key, el.checked);
        else if (f.type === 'number') {
          setByPath(state.config, f.key, el.value === '' ? null : Number(el.value));
        } else if (f.type === 'select') {
          let v = el.value;
          if (/^-?\d+(\.\d+)?$/.test(v)) v = Number(v);
          setByPath(state.config, f.key, v);
        } else {
          setByPath(state.config, f.key, el.value);
        }
      });
    });
    return deepClone(state.config);
  }

  function showProbeImages(urls) {
    const gal = document.getElementById('probeGallery');
    if (!gal) return;
    if (!urls || (!urls.spectrum && !urls.time && !urls.hist)) {
      gal.innerHTML = '<div class="probe-empty">探针完成但未找到图片，请查看日志。</div>';
      return;
    }
    const bust = 't=' + Date.now();
    const items = [
      { k: 'spectrum', title: '频谱 (Welch PSD)' },
      { k: 'time', title: '时域 (I / Q / |IQ|)' },
      { k: 'hist', title: '直方图' },
      { k: 'pbDebug', title: '脉冲消隐 PB debug（输入 / 输出 / 门限）' },
    ];
    const html = items.filter((it) => urls[it.k]).map((it) => `
      <div class="probe-fig">
        <h3>${it.title}</h3>
        <img src="${urls[it.k]}?${bust}" alt="${it.title}" />
      </div>`).join('');
    gal.innerHTML = html || '<div class="probe-empty">探针完成但未找到图片，请查看日志。</div>';
  }

  async function startRun() {
    const cfg = collectConfig();
    $('btnRun').disabled = true;
    $('btnProbe').disabled = true;
    setStatusPill('running');
    $('jobKind').textContent = 'pipeline';
    $('jobNav').textContent = '—';
    appendLog('', true);
    appendLog('提交全流程任务…\n');
    try {
      const res = await api('/api/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config: cfg }),
      });
      state.jobId = res.jobId;
      $('jobId').textContent = res.jobId;
      $('jobOut').textContent = res.outDir || '—';
      $('btnOpen').disabled = false;
      startPoll();
    } catch (e) {
      setStatusPill('failed');
      appendLog('错误: ' + e.message + '\n');
      $('btnRun').disabled = false;
      $('btnProbe').disabled = false;
    }
  }

  async function startProbe() {
    activateTab('probe');
    const cfg = collectConfig();
    $('btnRun').disabled = true;
    $('btnProbe').disabled = true;
    const bi = document.getElementById('btnProbeInline');
    if (bi) bi.disabled = true;
    setStatusPill('running');
    $('jobKind').textContent = 'probe';
    $('jobNav').textContent = '—';
    appendLog('', true);
    appendLog('提交 IF 探针（时域 + 频谱）…\n');
    const gal = document.getElementById('probeGallery');
    if (gal) gal.innerHTML = '<div class="probe-empty">MATLAB 生成图像中…</div>';
    try {
      const res = await api('/api/probe', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config: cfg }),
      });
      state.jobId = res.jobId;
      $('jobId').textContent = res.jobId;
      $('jobOut').textContent = res.outDir || '—';
      $('btnOpen').disabled = false;
      startPoll(true);
    } catch (e) {
      setStatusPill('failed');
      appendLog('探针错误: ' + e.message + '\n');
      $('btnRun').disabled = false;
      $('btnProbe').disabled = false;
      if (bi) bi.disabled = false;
    }
  }

  function startPoll(isProbe) {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = setInterval(() => pollJob(isProbe), 1200);
    pollJob(isProbe);
  }

  async function pollJob(isProbe) {
    if (!state.jobId) return;
    try {
      const job = await api('/api/job/' + encodeURIComponent(state.jobId));
      setStatusPill(job.status || 'idle');
      if (job.kind) $('jobKind').textContent = job.kind;
      if (job.log) appendLog(job.log, true);
      if (job.outDir) $('jobOut').textContent = job.outDir;

      if (job.report && job.report.navSummary) {
        const n = job.report.navSummary;
        $('jobNav').textContent =
          `fixes=${n.nFixes ?? '—'}  ` +
          (n.meanLat != null && isFinite(n.meanLat)
            ? `${Number(n.meanLat).toFixed(6)}, ${Number(n.meanLon).toFixed(6)}  h=${Number(n.meanH).toFixed(1)}m`
            : '');
      }

      if (job.status === 'done' || job.status === 'failed') {
        clearInterval(state.pollTimer);
        state.pollTimer = null;
        $('btnRun').disabled = false;
        $('btnProbe').disabled = false;
        const bi = document.getElementById('btnProbeInline');
        if (bi) bi.disabled = false;

        if (job.report && job.report.error) {
          appendLog('\n[report.error] ' + job.report.error + '\n');
        }
        // Probe images
        if ((isProbe || job.kind === 'probe') && job.report) {
          const urls = job.report.imageUrls || {};
          if (job.id) {
            const base = '/api/files/' + job.id + '/probe/';
            if (!urls.spectrum) urls.spectrum = base + 'probe_spectrum.png';
            if (!urls.time) urls.time = base + 'probe_time.png';
            if (!urls.hist) urls.hist = base + 'probe_hist.png';
            // PB debug only if report listed it or MATLAB wrote the path
            const hasPb = (job.report.images && job.report.images.pbDebug)
              || job.report.pbEnabled === true;
            if (!urls.pbDebug && hasPb) {
              urls.pbDebug = base + 'probe_pb_debug.png';
            }
          }
          showProbeImages(urls);
          activateTab('probe');
        }
      }
    } catch (e) {
      appendLog('\n轮询失败: ' + e.message + '\n');
    }
  }

  async function openResults() {
    const out = $('jobOut').textContent;
    if (!out || out === '—') return;
    try {
      await api('/api/open', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ outDir: out }),
      });
    } catch (e) {
      appendLog('打开结果失败: ' + e.message + '\n');
    }
  }

  function exportJson() {
    const cfg = collectConfig();
    const blob = new Blob([JSON.stringify(cfg, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'b2a_ui_config.json';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  function resetDefaults() {
    state.config = deepClone(state.defaults);
    (state.schema.tabs || []).forEach((tab) => renderFields(tab));
    appendLog('已恢复默认配置\n');
  }

  async function init() {
    try {
      const health = await api('/api/health');
      $('verBadge').textContent = 'v' + (health.version || '0.1.6');
      const mb = $('matlabBadge');
      if (health.matlabFound) {
        mb.textContent = 'MATLAB OK';
        mb.className = 'badge badge-ok';
        mb.title = health.matlab || '';
      } else {
        mb.textContent = 'MATLAB 未找到';
        mb.className = 'badge badge-err';
        mb.title = '设置环境变量 B2A_MATLAB';
      }

      state.schema = await api('/api/schema');
      state.defaults = await api('/api/defaults');
      if (Array.isArray(state.defaults.acqSatelliteList)) {
        state.defaults.acqSatelliteList = state.defaults.acqSatelliteList.join(',');
      }
      state.config = deepClone(state.defaults);
      renderTabs();
      setStatusPill('idle');
      appendLog('就绪。可先在「数据 / IF」确认文件，再运行探针或全流程。\n');
    } catch (e) {
      appendLog('初始化失败: ' + e.message + '\n请运行 python launch_b2a_ui.py\n');
    }

    $('btnRun').addEventListener('click', startRun);
    $('btnProbe').addEventListener('click', startProbe);
    $('btnReset').addEventListener('click', resetDefaults);
    $('btnExport').addEventListener('click', exportJson);
    $('btnOpen').addEventListener('click', openResults);
    $('btnRefresh').addEventListener('click', () => pollJob(false));
  }

  document.addEventListener('DOMContentLoaded', init);
})();
