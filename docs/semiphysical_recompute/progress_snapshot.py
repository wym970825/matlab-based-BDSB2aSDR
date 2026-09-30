"""Small, read-only progress snapshot for the isolated five-case run."""
from pathlib import Path
import datetime as dt
import json
import re
import sys

root = Path(__file__).resolve().parents[2]
run = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'results/semiphysical_recompute/20260930_restart_isolated'
state = json.loads((run / 'supervisor.json').read_text('utf-8'))
result = dict(at=dt.datetime.now().astimezone().isoformat(), status=state['status'],
              complete=sum(x['status'] == 'done' for x in state['cases']),
              queued=[x['case'] for x in state['cases'] if x['status'] == 'pending'])
for case in state['cases']:
    if case['status'] not in ('running', 'starting'):
        continue
    folder = Path(case['outputDir'])
    report = folder / 'report.json'
    r = json.loads(report.read_text('utf-8')) if report.exists() else {}
    result.update(currentCase=case['case'], stage=r.get('stage', 'MATLAB startup'))
    log = Path(case['attempts'][-1]['directory']) / 'matlab.log'
    last = {}
    if log.exists():
        with log.open('rb') as fh:
            fh.seek(max(0, log.stat().st_size - 262144))
            tail = fh.read().decode('utf-8', errors='replace')
        for seconds, prn in re.findall(r'\|T\|\s*([\d.]+)d\|[^\n]*?PRN:\s*(\d+)', tail):
            last[int(prn)] = float(seconds)
    finals = {int(re.search(r'Prn_(\d+)', p.name)[1]) for p in (folder / 'temp').glob('*_final.mat')}
    n = r.get('nAcquired', 0)
    total = len(finals)*715 + sum(v for k,v in last.items() if k not in finals)
    result.update(completedSatellites=len(finals), acquiredSatellites=n,
                  trackingPercentApprox=round(100*total/(n*715), 1) if n else None,
                  activeSatelliteSeconds={k:v for k,v in last.items() if k not in finals})
print(json.dumps(result, ensure_ascii=False))
