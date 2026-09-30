"""Record completion only after RF validation and both runtime regressions."""
from pathlib import Path
import datetime as dt
import hashlib
import json

root = Path(__file__).resolve().parents[2]
run = root / 'results/semiphysical_recompute/20260930_restart_isolated'
read = lambda path: json.loads(path.read_text('utf-8'))
state = read(run / 'supervisor.json')
assert state['status'] == 'done' and len(state['cases']) == 5
reviews = [read(run / 'review' / c['case'] / 'data_review.json') for c in state['cases']]
for review in reviews:
    assert review['validation']['ok'] and not review['validation']['configDifferences']
    assert len(review['tracks']) == 8
    for tr in review['tracks']:
        assert tr['samples'] == tr['finiteSamples'] == tr['timestampSamples'] == 715000
        assert tr['nonIncreasingAbsoluteSamples'] == tr['reacqMs'] == 0
checks = [read(run / f'post_apply_{release}.json') for release in ('2026a', '2024b')]
assert all(c['ok'] and c['passed'] == 38 and c['failed'] == c['incomplete'] == 0
           and c['batchOrchestration']['ok'] for c in checks)
applied = read(run / 'fixes_applied.json')
for path, meta in applied['files'].items():
    assert hashlib.sha256((root / path).read_bytes()).hexdigest() == meta['candidateSha256']
frozen = read(run / 'frozen_source_verification.json')
assert frozen['ok'] and not frozen['changedFiles']
for stem in ('tracking_comparison', 'statistics_comparison'):
    for extension in ('png', 'pdf'):
        assert (run / 'review' / f'{stem}.{extension}').is_file()
completed = dt.datetime.now().astimezone().isoformat()
applied.update(postApplyRegression='passed', postApplyReleases=[c['release'] for c in checks],
               finalizedAt=completed)
(run / 'fixes_applied.json').write_text(json.dumps(applied, indent=2), encoding='utf-8')
evidence = dict(completedAt=completed, ok=True, cases=5, completeTracks=40,
                nativeSamplesPerTrack=715000, sourceFixesApplied=len(applied['files']),
                frozenSourceFilesChecked=frozen['filesChecked'],
                runtimeChecks=[dict(release=c['release'], passed=c['passed'],
                                    batchOrchestrationOK=c['batchOrchestration']['ok']) for c in checks],
                originalResultsPreserved=True,
                notes=['No simulator coordinate or injection-time truth supplied.',
                       'S4 thermal correction remains a high-SNR Gaussian approximation.',
                       'R2026a parallel workers and inactive KF dynamics are not validated by these RF runs.'])
(run / 'completion_audit.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
print(json.dumps(evidence))
