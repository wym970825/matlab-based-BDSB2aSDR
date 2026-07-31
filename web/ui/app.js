/* B2a Web UI — tabbed config + run full pipeline via Python/MATLAB */
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
    return v == null ? '' : String(v);
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
    if (status === 'done') bar.style.width = '100%';
    else if (status === 'failed') bar.style.width = '100%';
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
      panel.innerHTML = `<p class="tab-desc">${tab.description || ''}</p><div class="fields" id="fields-${tab.id}"></div>`;
      panels.appendChild(panel);
      renderFields(tab);
    });
    state.activeTab = tabs[0] && tabs[0].id;
  }

  function renderFields(tab) {
    const box = document.getElementById('fields-' + tab.id);
    box.innerHTML = '';
    (tab.fields || []).forEach((f) => {
      const wrap = document.createElement('div');
      const isBool = f.type === 'bool';
      wrap.className = 'field' + (isBool ? ' bool' : '') + (f.path || f.key === 'filePath' || f.key === 'fileName' || f.key === 'acqSatelliteList' ? ' full' : '');

      const id = 'f_' + f.key.replace(/\./g, '_');
      let val = getByPath(state.config, f.key);
      if (f.key === 'acqSatelliteList') val = formatAcqList(val);
      if (val === undefined || val === null) val = '';

      if (isBool) {
        wrap.innerHTML = `
          <input type="checkbox" id="${id}" ${val ? 'checked' : ''} />
          <label for="${id}">${f.label}</label>
        `;
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
          ${f.hint ? `<span class="hint">${f.hint}</span>` : ''}
        `;
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
          ${f.hint ? `<span class="hint">${f.hint}</span>` : ''}
        `;
        wrap.querySelector('input').addEventListener('change', (e) => {
          const v = e.target.value === '' ? null : Number(e.target.value);
          setByPath(state.config, f.key, v);
        });
      } else {
        wrap.innerHTML = `
          <label for="${id}">${f.label}</label>
          <input type="text" id="${id}" value="${String(val).replace(/"/g, '&quot;')}" />
          ${f.hint ? `<span class="hint">${f.hint}</span>` : ''}
        `;
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
    // re-read all inputs to be safe
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

  async function startRun() {
    const cfg = collectConfig();
    $('btnRun').disabled = true;
    setStatusPill('running');
    $('jobNav').textContent = '—';
    appendLog('', true);
    appendLog('提交任务…\n');
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
    }
  }

  function startPoll() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = setInterval(pollJob, 1500);
    pollJob();
  }

  async function pollJob() {
    if (!state.jobId) return;
    try {
      const job = await api('/api/job/' + encodeURIComponent(state.jobId));
      setStatusPill(job.status || 'idle');
      if (job.log) appendLog(job.log, true);
      if (job.outDir) $('jobOut').textContent = job.outDir;
      if (job.report && job.report.navSummary) {
        const n = job.report.navSummary;
        $('jobNav').textContent =
          `fixes=${n.nFixes ?? '—'}  ` +
          (n.meanLat != null ? `${Number(n.meanLat).toFixed(6)}, ${Number(n.meanLon).toFixed(6)}  h=${Number(n.meanH).toFixed(1)}m` : '');
      }
      if (job.status === 'done' || job.status === 'failed') {
        clearInterval(state.pollTimer);
        state.pollTimer = null;
        $('btnRun').disabled = false;
        if (job.report && job.report.error) {
          appendLog('\n[report.error] ' + job.report.error + '\n');
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
    // re-render fields
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
        mb.title = '设置环境变量 B2A_MATLAB 指向 matlab.exe';
      }

      state.schema = await api('/api/schema');
      state.defaults = await api('/api/defaults');
      // normalize acq list display
      if (Array.isArray(state.defaults.acqSatelliteList)) {
        state.defaults.acqSatelliteList = state.defaults.acqSatelliteList.join(',');
      }
      state.config = deepClone(state.defaults);
      renderTabs();
      setStatusPill('idle');
      appendLog('就绪。配置各 Tab 后点击「运行全流程」。\n');
    } catch (e) {
      appendLog('初始化失败: ' + e.message + '\n请用 launch_b2a_ui.py 启动服务。\n');
    }

    $('btnRun').addEventListener('click', startRun);
    $('btnReset').addEventListener('click', resetDefaults);
    $('btnExport').addEventListener('click', exportJson);
    $('btnOpen').addEventListener('click', openResults);
    $('btnRefresh').addEventListener('click', pollJob);
  }

  document.addEventListener('DOMContentLoaded', init);
})();
