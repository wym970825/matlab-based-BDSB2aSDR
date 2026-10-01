"""Sequential full multi-SV TF runs in isolated MATLAB processes.

One process per case keeps memory/pool state isolated. Preflight all five,
then a 5 s parallel smoke run, then all five 715 s runs. Never overwrite an
existing report or retry a live process; explicit failures stop the queue.
"""
from pathlib import Path
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'results/Exp00-newTFPB'
MATLAB = Path('C:/Program Files/MATLAB/R2024b/bin/matlab.exe')


def now():
    return dt.datetime.now().astimezone().isoformat()


def write_json(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode())
    temp.replace(path)


def hidden():
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0
    return dict(startupinfo=si, creationflags=subprocess.CREATE_NO_WINDOW)


def supervise():
    sys.path.insert(0, str(ROOT / 'python'))
    from b2a_ui.matlab_runner import _matlab_clean_env
    plan = json.loads((OUTPUT / 'experiment_plan.json').read_text('utf-8'))
    state = dict(status='running', startedAt=now(), supervisorPid=os.getpid(), jobs=[])
    expected = json.loads((OUTPUT / 'source_manifest.json').read_text('utf-8'))

    def persist():
        state['updatedAt'] = now()
        write_json(OUTPUT / 'experiment_status.json', state)

    try:
        for phase, indices in [('preflight', range(1, 6)), ('smoke', [4]), ('full', range(1, 6))]:
            for index in indices:
                changed = [p for p, h in expected.items() if hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != h]
                if changed:
                    raise RuntimeError(f'Sources changed during experiment: {changed}')
                runtime = OUTPUT / '_runtime' / f'{phase}_{index:02d}'
                runtime.mkdir(parents=True, exist_ok=False)
                env = _matlab_clean_env(str(MATLAB))
                env.update(MATLAB_PREFDIR=str(runtime / 'prefs'), B2A_JOB_DIR=str(runtime / 'jobs'),
                           B2A_COMPLETION_PATH=str(runtime / 'completion.json'))
                code = ("try,setupPaths;addpath('docs/exp00_newtfpb');"
                        f"c=run_exp00_case({index},'{phase}');"
                        "if c.ok,exit(0);else,exit(1);end;catch ME,disp(getReport(ME));exit(2);end")
                record = dict(phase=phase, index=index, case=plan['cases'][index-1]['id'],
                              startedAt=now(), status='running', runtime=str(runtime))
                state['jobs'].append(record)
                state.update(phase=phase, currentCase=index)
                with (runtime / 'console.log').open('wb') as log:
                    proc = subprocess.Popen([str(MATLAB), '-nosplash', '-nodesktop', '-wait',
                        '-logfile', str(runtime / 'matlab.log'), '-r', code],
                        cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, **hidden())
                    record['launcherPid'] = proc.pid
                    persist()
                    while proc.poll() is None:
                        time.sleep(15)
                        persist()
                record.update(exitCode=proc.returncode, finishedAt=now())
                path = runtime / 'completion.json'
                result = json.loads(path.read_text('utf-8')) if path.is_file() else {'ok': False, 'error': 'No completion record; inspect process logs.'}
                record['completion'] = result
                record['status'] = 'done' if result['ok'] and proc.returncode == 0 else 'failed'
                persist()
                if record['status'] != 'done':
                    raise RuntimeError(f"{phase} case {index} failed; see {runtime}")
        state.update(status='complete', phase='done', finishedAt=now())
        persist()
    except BaseException as exc:
        state.update(status='failed', error=repr(exc), finishedAt=now())
        persist()
        raise


if __name__ == '__main__':
    if '--foreground' in sys.argv:
        supervise()
    else:
        assert not (OUTPUT / 'launch.json').exists(), 'Existing launch: inspect it instead of submitting twice.'
        with (OUTPUT / 'supervisor.log').open('ab') as log:
            proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--foreground'],
                                    cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, **hidden())
        record = dict(supervisorPid=proc.pid, startedAt=now(), output=str(OUTPUT))
        write_json(OUTPUT / 'launch.json', record)
        print(json.dumps(record))
