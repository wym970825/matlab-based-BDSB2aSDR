"""Restart pending experiments in isolated MATLAB processes, preserving attempts.

Completed experiments are reused only with a passing audit and unchanged source.
No RF data, original configurations, or previous output directories are modified.
"""
from pathlib import Path
import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
PKG = Path(__file__).resolve().parent
MATLAB = Path('C:/Program Files/MATLAB/R2024b/bin/matlab.exe')
PREVIOUS = ROOT / 'results/semiphysical_recompute/20260929_debug_fixed_r2024b'


def write_json(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')
    temp.replace(path)


def now():
    return dt.datetime.now().astimezone().isoformat()


def hidden_options():
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0
    return dict(startupinfo=si, creationflags=subprocess.CREATE_NO_WINDOW)


def supervise(output):
    sys.path.insert(0, str(ROOT / 'python'))
    from b2a_ui.matlab_runner import _matlab_clean_env
    hashes = json.loads((PREVIOUS / 'receiver_source_hashes.json').read_text('utf-8'))
    changed = [p for p, h in hashes.items()
               if hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != h]
    if changed:
        raise RuntimeError(f'Receiver changed since validated baseline: {changed}')
    write_json(output / 'receiver_source_hashes.json', hashes)
    manifest = json.loads((PKG / 'five_cases.json').read_text('utf-8'))
    baseline = PREVIOUS / 'dme_free'
    assert json.loads((baseline / 'validation.json').read_text('utf-8'))['ok']
    state_path = output / 'supervisor.json'
    if state_path.exists():
        state = json.loads(state_path.read_text('utf-8'))
    else:
        state = dict(startedAt=now(), status='running', cases=[
            dict(index=c['index'], case=c['id'], status='pending', attempts=[])
            for c in manifest['cases']])
        state['cases'][0].update(status='done', reused=True, outputDir=str(baseline))
    state.update(supervisorPid=os.getpid(), resumedAt=now(), status='running')

    def persist():
        state['updatedAt'] = now()
        write_json(state_path, state)
        rows = []
        for item in state['cases']:
            row = {k: item.get(k, '') for k in ('index', 'case', 'status', 'outputDir')}
            dest = Path(item.get('outputDir', ''))
            validation = dest / 'validation.json'
            if validation.is_file():
                a = json.loads(validation.read_text('utf-8'))
                row.update(validationOK=a.get('ok'), fixes=a.get('navigationFixes'),
                           prn11Samples=a.get('prn11Samples'), prn11ReacqMs=a.get('prn11ReacqMs'),
                           prn11MedianCNo=a.get('prn11MedianCNo'))
            rows.append(row)
        temp = output / 'recompute_summary.csv.tmp'
        with temp.open('w', newline='', encoding='utf-8-sig') as fh:
            w = csv.DictWriter(fh, fieldnames=['index', 'case', 'status', 'outputDir',
                'validationOK', 'fixes', 'prn11Samples', 'prn11ReacqMs', 'prn11MedianCNo'])
            w.writeheader(); w.writerows(rows)
        temp.replace(output / 'recompute_summary.csv')

    persist()
    for item in state['cases']:
        if item['status'] == 'done':
            continue
        # A process crash gets one retry; an explicit receiver error does not.
        for _ in range(2):
            attempt = len(item['attempts']) + 1
            attempt_dir = output / f"case_{item['index']:02d}_attempt_{attempt:02d}"
            attempt_dir.mkdir()
            item.update(status='starting', outputDir=str(attempt_dir / 'output' / item['case']))
            record = dict(attempt=attempt, startedAt=now(), directory=str(attempt_dir))
            item['attempts'].append(record)
            env = _matlab_clean_env(str(MATLAB))
            env.update(MATLAB_PREFDIR=str(attempt_dir / 'prefs'),
                       B2A_CASE_INDEX=str(item['index']),
                       B2A_CASE_ROOT=str(attempt_dir / 'output'),
                       B2A_JOB_DIR=str(attempt_dir / 'jobs'),
                       B2A_COMPLETION_PATH=str(attempt_dir / 'completion.json'))
            script = (PKG / 'run_isolated_case.m').as_posix().replace("'", "''")
            with (attempt_dir / 'console.log').open('wb') as console:
                proc = subprocess.Popen([str(MATLAB), '-nosplash', '-nodesktop', '-wait',
                    '-logfile', str(attempt_dir / 'matlab.log'), '-r',
                    f"try,run('{script}');catch ME,disp(getReport(ME));exit(2);end"],
                    cwd=ROOT, env=env, stdout=console, stderr=subprocess.STDOUT,
                    **hidden_options())
                record['launcherPid'] = proc.pid
                item['status'] = 'running'
                persist()
                while proc.poll() is None:
                    time.sleep(15)
                    persist()
            record.update(exitCode=proc.returncode, finishedAt=now())
            completion_file = attempt_dir / 'completion.json'
            if completion_file.exists():
                result = json.loads(completion_file.read_text('utf-8'))
                record['completion'] = result
                item['status'] = 'done' if result['ok'] else 'failed'
                persist()
                break
            item['status'] = 'interrupted'
            persist()
    state.update(status='done' if all(c['status'] == 'done' for c in state['cases'])
                 else 'incomplete', finishedAt=now())
    persist()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    parser.add_argument('--foreground', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / 'results/semiphysical_recompute'):
        raise ValueError('Output must be within workspace semiphysical_recompute results.')
    output.mkdir(parents=True, exist_ok=True)
    if args.foreground:
        try:
            supervise(output)
        except Exception as exc:
            write_json(output / 'supervisor_error.json', dict(error=repr(exc), at=now()))
            raise
    else:
        # Existing output is resumable only when the prior supervisor has stopped.
        previous_state = output / 'supervisor.json'
        if previous_state.exists():
            raise RuntimeError('For an existing run, verify it is stopped and use --foreground.')
        with (output / 'supervisor.log').open('ab') as log:
            proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                str(output), '--foreground'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                **hidden_options())
        write_json(output / 'launch.json', dict(supervisorPid=proc.pid, startedAt=now()))
        print(json.dumps(dict(supervisorPid=proc.pid, output=str(output))))
