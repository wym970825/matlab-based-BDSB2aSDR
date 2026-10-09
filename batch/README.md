# Directory batch processing

The function batchDirForOneSettings applies one receiver configuration to
every matching binary file in a directory. It accepts either a settings
struct returned by initSettings or a Web UI / JSON config file.

    cd('F:\matlab-GNSSsdr\BDS\B2a')
    setupPaths

    report = batchDirForOneSettings( ...
        'F:\Data\ExpKLHP\X310_IFData', ...
        'results\ui\260802_023720_944b90\ui_config.json');

Using a MATLAB settings struct:

    settings = initSettings('msToProcess', 60000, ...
        'acqSatelliteList', 1:60);
    report = batchDirForOneSettings( ...
        'F:\Data\ExpKLHP\X310_IFData', settings);

The default search is non-recursive *.bin. Useful options:

    report = batchDirForOneSettings(inputDir, settingsSource, ...
        'OutputRoot', 'F:\results\b2a_batch', ...
        'Recursive', false, ...
        'ContinueOnError', true, ...
        'OpenBaiduBrowser', false);

Each input gets a numbered output directory with an independent `ui_config.json`,
temp directory, result MAT files, `figures/AcqResult`, `figures/trkResult`,
`figures/navResult`, NMEA, and report.json. The batch
root contains batch_report.json and batch_report.mat, updated after every
file so completed progress remains visible after a later failure.

MATLAB identifiers cannot contain a hyphen, so the callable function uses
the valid name batchDirForOneSettings and the executable script uses
batch_dir_ForOneSettings.m. The exact requested name
batch-dir-ForOneSettings.m is retained for discoverability, but MATLAB
cannot invoke a hyphenated script with run. Define inputDir,
settingsSource, and optional batchOptions before running the underscore
script.

## DATA1020 seven-file experiment

`run_data1020_experiments` handles the seven selected 2022 Beijing recordings,
including the two files whose RF center is 1175.4 MHz (digital IF +1.05 MHz).
It reads little-endian interleaved int16 IQ at 20 MHz. All outputs are isolated
from the input recordings and existing results.

    setupPaths
    outputRoot = 'F:/matlab-GNSSsdr/BDS/B2a/results/data1020/my_new_run';
    run_data1020_experiments('prepare', outputRoot);
    run_data1020_experiments('smoke', outputRoot, [1 6 7]);
    verify_data1020_parallel_acquisition(outputRoot);
    run_data1020_experiments('full', outputRoot, 1:7);

Preparation samples 21 ten-millisecond windows across each recording, applies
the receiver's adaptive complex-PB threshold formula with Pfa=1e-4, and freezes
the median estimate as an explicit ADC amplitude for both acquisition and
tracking. No adaptive threshold updates occur during the actual runs.
The probes retain per-window threshold estimates, blanking duty and clipping
statistics. The given gain values are retained; ADC thresholds avoid dependence
on the conflicting gain metadata in old UI configurations.

Smoke uses four known candidate PRNs and five seconds. Full runs search PRN
1:63 with 63 available channels, then track all detections for the file duration
minus the receiver's required one-second tail reserve. The full runner enables
`useParallelAcquisition`: up to six process workers call the unchanged coarse/
fine acquisition kernel independently per PRN. This option defaults to off in
other callers; `verify_data1020_parallel_acquisition` checks exact equality of
every serial/parallel result field on both zero-IF and nonzero-IF real inputs.
Tracking likewise partitions only active channels while retaining the original
reserved output slots. `verify_data1020_active_scheduling(outputRoot)` compares
six channels against the earlier saved first-case output, including raw
correlators, sample indices, loop values, states and PB duty.

`run_data1020_experiments('tail', outputRoot, 1)` independently restarts the
first file at 75% of its duration, using the same static threshold and a fresh
1:63 search. Its products are kept separately; this is not a seamless splice
or a claim of continuous lock across an outage.

Per-run products include replayable configuration, effective settings, captured
PRN metrics, per-PRN tracking statistics, native tracking MAT files, navigation,
NMEA, acquisition/tracking/navigation PNGs, logs and validation JSON. The batch
summary is updated after every completed item. Repeated calls skip completed
items and refuse to overwrite incomplete directories. `pipelineOk` denotes
successful execution; navigation fix counts and tracking coverage must still
be inspected separately. The dated `launch_data1020_*.m` scripts reproduce the
2026-10-08 run; use a new output root for a new experiment.

Create an offline HTML index (standard-library Python only), or inspect live
stage/heartbeat progress:

    python batch/data1020_report.py results/data1020/20261008_static_pb_run02
    python batch/data1020_report.py results/data1020/20261008_static_pb_run02 --status

The HTML distinguishes finite navigation solutions from quality-screened
trajectory points. It reports raw GGA height statistics and extreme candidates
without deleting raw results or treating unverified coordinates as truth.
`experiment_summary.csv` also records full-length channel counts, early-ended
PRNs, the static threshold, IF, gain and figure counts. Full-length recording
includes re-acquisition intervals and is not a continuous-lock claim.
After the dated batch completes, `finalize_data1020_figures.m` re-exports
readable all-PRN acquisition plots and per-channel tracking plots, records the
exact navigation plot filter counts, and audits duplicate/backward sample
steps. It does not rerun tracking or change numerical results. Regenerate the
HTML index after this finalization.
`export_data1020_offline_maps(outputRoot)` also regenerates longitude/latitude
tracks without online basemap tiles, avoiding saved "Loading" placeholders.

## DATA1020 six-pair PB / TF comparison (2026-10-09)

The six valid recordings exclude the original `HUR` recording (but retain
`HUR_1` and `HUR_2`). They are ordered by their first valid GGA / ZDA UTC:
beiqijiatai, HUR_1, HUR_2, 103330, 103801, 111407. The dated output root is
`results/data1020/20261009_pb_tf_comparison`; `manifest.json` maps original
names, renamed PB directories and matching `-TF` directories.

`analyze_data1020_dme(manifestPath)` reads 61 evenly spaced 50-ms raw IQ
windows per recording and exports full-band Welch spectra, high-energy-frame
spectra, time/frequency plots and station-distance evidence. A second argument
of zero only redraws already saved spectral data. The 1181-MHz Guanzhuang
association for beiqijiatai is a weak candidate; the other five cases show
strong 1170-MHz evidence near Huairou. Frequency and distance do not uniquely
identify a transmitter. The user-supplied N/E coordinate prefixes determine
latitude/longitude, despite the reversed original table column headings.

`prepare_data1020_comparison.py` writes the checked relocation plan and final
manifest; it does not move or delete files. Directory relocation uses explicit
PowerShell LiteralPath operations. `rebase_data1020_pb_metadata` updates only
lightweight UI/replay paths and keeps the scientific MAT archives intact.

`run_data1020_tf_pairs(manifestPath,'smoke',[1 4 6])` verifies the three digital
notch centers. The `full` action searches PRN 1:63 and uses the corresponding
saved PB settings. The treatment is `TFBlankerV1`, 800-kHz stopband and 3-us
triangle span, with the same frozen ADC detector threshold. Digital center is
station RF frequency minus recording RF center (not minus B2a RF frequency).
Every run checks a direct-convolution reference. Full runs also compare both
pre-run and saved effective settings: only the frontend, its derived EnablePB
flag, output metadata and resource scheduling may differ. Resource-only fields
are `parMaxWorkers`, `useParfor`, and `useParallelAcquisition`.

Use MATLAB `-batch -singleCompThread`; all figures are invisible. The dated
`launch_data1020_tf_preflight.m` and `launch_data1020_tf_full.m` scripts perform
smoke/self-comparison and the six full runs respectively. Files are processed
sequentially. The full launcher closes its worker pool before final plotting
and comparison to reduce memory use.

After the host crash in TF case 5, recovery retains its eight already saved
per-PRN final files (six full-length and two naturally ended early). PRN 25 and
30 are recomputed from the beginning of their source data; PRN 25's two saved
60,000-record chunks are not spliced into a resumed track. These chunks contain
output records, not complete loop/state-machine checkpoints. Case 6 is run one
satellite at a time. Both recovery stages use one R2024b process with
`-singleCompThread`, no pool, `useParfor=false`,
`useParallelAcquisition=false`, and `parMaxWorkers=1`. Cases 1--4 retain their
original parallel flags and at most two workers. Case 5's final resource flags
describe recovery; its eight reused final files still originate from the
earlier two-worker run. `recovery_audit.json` records this mixed execution
provenance and is linked from both report pages when present.

This changes execution scheduling, not the receiver numerical sources, source
samples, requested duration, acquisition/tracking parameters, frozen threshold,
or TF filter configuration. It does not establish bitwise equivalence between
serial and parallel execution, and scheduling is not an interference-treatment
effect. Comparison conclusions continue to use saved per-satellite results,
physical sample times, and independent final validation. Missing results remain
pending until all required per-PRN files and navigation outputs are validated.

`export_data1020_satellite_maps` caches Esri World Imagery tiles and renders
offline satellite maps, common PB/TF geographic bounds, the matched station,
and the exact purple/orange CIELAB palette from the supplied reference script.
No map-loading placeholder or visible browser is required.

`compare_data1020_pb_tf` writes the comparison brief and per-PRN interval CSVs.
It distinguishes continuous non-REACQ intervals from continuous LONG states,
uses actual saved sample counts, and matches elevation to PRN in the original
navigation channel slots. It reports both separately qualifying PB/TF intervals
and the stricter common physical interval of at least 180 s above 30 degrees.
Missing/rejected navigation epochs are not bridged or extrapolated. TF weights
are reported separately from PB's full-band blanking fraction.

    python batch/report_data1020_pb_tf.py results/data1020/20261009_pb_tf_comparison

This updates the offline gallery and brief using actual completed outputs;
unfinished TF cases remain visibly pending. Navigation availability, residuals
and PB/TF disagreement are not absolute accuracy without an external reference.

`launch_data1020_tf_finalize.m` operates only on completed saved results. It
exports all twelve acquisition figures at 1800 x 1000 pixels and redraws each
tracking figure with separate PLL phase-error / carrier-NCO axes and DLL-error /
code-NCO axes. Tracking plots retain explicitly labelled nominal tick time;
the 180-s selection still uses physical source-sample time. Short state changes
are retained when plotting. Each source MAT is checked for unchanged size and
modification time, with figure audits written under `analysis`.

After the full launcher and MATLAB finalization finish, run:

    python batch/finalize_data1020_provenance.py results/data1020/20261009_pb_tf_comparison
    python batch/verify_data1020_comparison.py results/data1020/20261009_pb_tf_comparison/comparison
    python batch/report_data1020_pb_tf.py results/data1020/20261009_pb_tf_comparison
    python batch/validate_data1020_pb_tf.py results/data1020/20261009_pb_tf_comparison

The independent comparison check recomputes interval intersections and list
qualifications from exported JSON/CSV. The package audit checks all twelve
runs, conditions, maps, plots, links and raw-file sampled fingerprints. The
fingerprints cover first/middle/last 64-KiB blocks, size and modification time;
they are not whole-file checksums. `--allow-pending` allows an intermediate
package audit to exit successfully but never marks an incomplete package as
complete.

The provenance step preserves the startup `source_manifest.json` and writes
`final_source_manifest.json` only after all six TF runs and saved-result
postprocessing complete. It records the current Git HEAD and working-tree
source hashes, compares all 69 receiver source/MEX files with both PB and the
TF startup manifests, and lists changed/added DATA1020 batch `.m`, `.py`, and
`.ps1` scripts. `--inspect` prints a read-only preview while work is pending;
the formal command exits with code 2 without writing if completion is missing.
The package audit rechecks the recorded source bytes, not generated reports or
working-tree cleanliness, so regenerating HTML/JSON output does not invalidate
source provenance. Rerun provenance if source code changes after its capture.

`finish_data1020_tf_queue.ps1 -ReceiverProcessId <actual-MATLAB-engine-PID>`
waits for the specified receiver process before launching the saved-result
finalizer and the four Python steps above. Start it with a hidden PowerShell
window. It records explicit success/failure under the result root and refuses
to proceed without full receiver and comparison completion records.
`python batch/data1020_live_status.py` reads progress JSON/logs without loading
MAT or IQ data.

For the 2026-10-09 crash recovery, `resume_data1020_tf_queue.ps1` runs one
R2024b `-batch -singleCompThread` process per stage and waits for it to exit
before starting the next. It resumes experiments 5 and 6 only, then performs
the common maps, comparison, figure finalization and package audits. Do not
start a second queue while the recorded `recovery_runner_process.json`
process is active. An optional `-PrepareProcessId` waits for an already
running manual preparation stage.

`run_data1020_recovery_stage(manifestPath,index,action[,prn])` supports
`prepare`, `track` and `finish`. Preparation saves exact acquisition and
63-slot channel metadata in `recovery_state.mat`. Complete satellite files
are reused; incomplete channel chunks are archived and the whole channel is
recomputed from its acquisition origin. Chunks do not preserve complete loop
state and are never spliced to cold-started tracking. The independent
`finalize_data1020_saved_run` and `audit_data1020_tf_run` helpers keep the
receiver's numerical files unchanged. `record_data1020_recovery.py ROOT`
records the eight preserved final-file SHA256 values; `--verify` checks them
after all six runs finish. Experiment 5's recovery elapsed time excludes its
pre-crash work and outage, so it is not an uninterrupted runtime benchmark.

`verify_data1020_recovered_chunk.py` compares completed v7.3 chunk fields
through the HDF5 library without starting MATLAB. The archived and recovered
PRN 25 first chunks agree in all 83 numeric/logical fields and 8 character
fields. This only verifies those first 60,000 saved records. Different MAT
container hashes, including creation timestamps, are not numeric differences.
The recovery audit rechecks each source file against its own recorded hash.

`export_data1020_navigation_figures` reads navigation results and exports
five offline figures one at a time with explicit `Visible='off'`. It retains
the existing track filtering, ENU reference and velocity definitions; sky
labels match PRN, azimuth and elevation by original channel slot and epoch.
The recovery postprocessor redraws all twelve PB/TF navigation sets this way
before the cached satellite maps replace the labelled offline LLA previews.
The navigation figure audit records source size/timestamp stability, output
dimensions and display-only changes. Final visual QA follows that redraw.
