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
