"""Run the final regression with the same MATLAB release as the RF runs."""
from pathlib import Path
import datetime as dt
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
run = root / 'results/semiphysical_recompute/20260930_restart_isolated'
state = json.loads((run / 'supervisor.json').read_text('utf-8'))
assert state['status'] == 'done'
assert (run / 'fixes_applied.json').is_file()
folder = run / 'post_apply_r2024b_process'
folder.mkdir(exist_ok=False)
matlab = Path('C:/Program Files/MATLAB/R2024b/bin/matlab.exe')
sys.path.insert(0, str(root / 'python'))
from b2a_ui.matlab_runner import _matlab_clean_env

env = _matlab_clean_env(str(matlab))
env['MATLAB_PREFDIR'] = str(folder / 'prefs')
si = subprocess.STARTUPINFO()
si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
si.wShowWindow = 0
quote = lambda path: str(path).replace('\\', '/').replace("'", "''")
code = (f"try,addpath('{quote(root / 'docs/semiphysical_recompute')}');"
        f"verify_applied_diagnostics('{quote(run)}');exit(0);"
        "catch ME,disp(getReport(ME,'extended'));exit(2);end")
with (folder / 'console.log').open('wb') as log:
    proc = subprocess.Popen([str(matlab), '-nosplash', '-nodesktop', '-wait',
        '-logfile', str(folder / 'matlab.log'), '-r', code], cwd=root, env=env,
        stdout=log, stderr=subprocess.STDOUT, startupinfo=si,
        creationflags=subprocess.CREATE_NO_WINDOW)
record = dict(launcherPid=proc.pid, startedAt=dt.datetime.now().astimezone().isoformat())
(folder / 'launch.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
print(json.dumps(record))
