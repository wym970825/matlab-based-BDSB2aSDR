"""Apply verified candidates only after the five experiments have completed."""
from pathlib import Path
import datetime as dt
import hashlib
import json
import shutil

root = Path(__file__).resolve().parents[2]
run = root / 'results/semiphysical_recompute/20260930_restart_isolated'
state = json.loads((run / 'supervisor.json').read_text('utf-8'))
assert state['status'] == 'done' and all(c['status'] == 'done' for c in state['cases']), \
    'Never modify receiver code during the frozen five-case run.'
check = json.loads((run / 'candidate_checks.json').read_text('utf-8'))
assert check['ok'] and check['failed'] == 0, 'Candidate regression must pass first.'
manifest = json.loads((run / 'candidate_code/manifest.json').read_text('utf-8'))
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
frozen = json.loads((run / 'receiver_source_hashes.json').read_text('utf-8'))
changed = [relative for relative, expected in frozen.items() if sha(root / relative) != expected]
assert not changed, f'Frozen receiver source changed during experiments: {changed}'
(run / 'frozen_source_verification.json').write_text(json.dumps(dict(
    checkedAt=dt.datetime.now().astimezone().isoformat(), filesChecked=len(frozen),
    changedFiles=changed, ok=True), indent=2), encoding='utf-8')
for relative, meta in manifest.items():
    assert sha(root / relative) == meta['originalSha256'], f'Source changed: {relative}'
    assert sha(Path(meta['candidate'])) == meta['candidateSha256'], f'Candidate changed: {relative}'
    assert check['candidateHashes'][relative] == meta['candidateSha256'], f'Untested candidate: {relative}'
backup = run / 'source_before_final_fixes'
backup.mkdir(exist_ok=False)
for relative, meta in manifest.items():
    saved = backup / relative
    saved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / relative, saved)
    (root / relative).write_bytes(Path(meta['candidate']).read_bytes())
record = dict(appliedAt=dt.datetime.now().astimezone().isoformat(), files=manifest,
              baselineResultsPreserved=True, postApplyRegression='pending')
(run / 'fixes_applied.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
print(f'Applied {len(manifest)} verified fixes; original files preserved in {backup}')
