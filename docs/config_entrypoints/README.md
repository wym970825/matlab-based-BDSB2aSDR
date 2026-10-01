# JSON and MATLAB settings entry points

`config/initSettings.m` is the single configuration constructor. `core/runFromJsonConfig.m` accepts either a JSON path or a scalar MATLAB structure and sends both through that constructor. `core/runFromSettings.m` is a thin adapter that forwards only explicitly requested pipeline overrides.

## Equivalent calls

Start from the same configuration, keep the tag fixed when comparing products, and use separate output directories:

```matlab
setupPaths;
configPath = fullfile('docs','semiphysical_recompute','configs','04_2700_n50dBm.json');
cfg = jsondecode(fileread(configPath));

% JSON transport:
jsonReport = runFromJsonConfig(configPath,'outDir',fullfile('results','from_json'));

% The identical object without JSON transport:
structReport = runFromJsonConfig(cfg,'outDir',fullfile('results','from_struct'));

% Explicit settings construction and the settings adapter:
s = initSettings(cfg);
settingsReport = runFromSettings(s,'outDir',fullfile('results','from_settings'));

% Name/value construction is also supported for all configuration fields:
args = namedargs2cell(cfg);
s = initSettings(args{:});
```

These examples execute the duration in the supplied configuration. For a short check, change `cfg.msToProcess` and save that same modified object to a new JSON file before comparing. Do not compare a modified MATLAB configuration against the original unmodified JSON.

The equivalence contract concerns effective receiver settings and processing. Output directories, a generated timestamp tag, wall-clock timings, and file-container metadata can differ. `requestedMs` in the report describes the value passed to that runner: a settings object already capped by `initSettings` naturally contains the capped request. `effectiveMs` and the processed samples must agree. Use a fixed tag and compare settings after excluding only `outDir`, `resultRoot`, and `tempdataSvPth` when the destination folders intentionally differ.

`run_B2a` is an older orchestration API. It also uses `initSettings` and the same receiver modules, but retains its own `saveResults`, `saveTrackingFigures`, plot policy and return type. It is not a byte-for-byte substitute for the report/UI-product API documented here. Prefer `runFromSettings` when an experiment must replay identically through the JSON runner.

## Construction order and override rules

1. Define the existing receiver defaults in `initSettings`.
2. Merge the supplied scalar structure, or name/value overrides, into those defaults. Nested scalar structures merge recursively, so a partial `FLL`, `KF`, `PB_settings`, or `nmea` override does not erase other defaults.
3. Validate input geometry, compute bytes per real/complex sample, normalize PRN vectors, derive omitted dependent values and synchronize aliases.
4. Limit processing duration using the final sample rate, format and byte offset, reserving the existing one second of input at the tail.
5. The runner resolves the exclusive frontend mode, applies pipeline switches, and assigns its per-run output layout.

There is no JSON field whitelist. Fields such as `pllMaxNcoHz`, `pllSaturationHoldMs`, `pllSaturationNcoRatio`, `pllSaturationRatio`, `reacqCnoConsecutive`, and `reacqCnoRecoverDbHz` now survive both transports. Unknown extension fields are also preserved; this is not a complete schema validator, and a misspelled extension field will not configure an unrelated receiver parameter. Use the documented exact field names in JSON/structs. Known name/value keys retain case-insensitive matching; ambiguous partial-name matching is disabled.

| Field or group | Shared rule |
|---|---|
| `samplingFreq` | Positive sample rate in Hz; one sample means one real value for `fileType=1`, one I/Q pair for `fileType=2` |
| `dataType`, `fileType` | `size_per_sample` is always rederived; a stale supplied byte count is not trusted |
| `skipNumberOfBytes` | Explicit absolute byte offset wins; if absent, convert the legacy 3005-second skip using the final rate and format |
| `msToProcess` | At least 1 ms; floor to an integer and cap to available input minus the one-second reserve |
| `PB_settings.Th_static` | Explicit digital amplitude wins; otherwise convert `Th_static_dBm` with final `usrp.scaleK`, `usrp.gain`, and `samplingFreq` |
| `PB_settings.Th_static_tracking` | Explicit digital amplitude wins; otherwise convert `Th_static_tracking_dBm` using the same final calibration |
| `fineCodeSearchHalfWinSamples` | Explicit value wins; otherwise `ceil(2*samplingFreq/codeFreqBasis)` |
| `dllNoiseBandwidth_stab` | Canonical value wins over `dllNoiseBandwidth`; alias-only input is accepted and synchronized |
| `pllNoiseBandwidth_stab` | Canonical value wins over `pllNoiseBandwidth` |
| `pllNoiseBandwidth_pull` | Canonical value wins over `pllNoiseBandwidth_init` |
| `acqSatelliteList` | Normalize numeric input to a row; accept list/range text; reject invalid text instead of silently selecting fallback satellites |
| `REACQ_eachTimeWaitMs` | Normalize to a row; regenerate `100*(0:N-1)` if its length differs from rounded `REACQ_max` |
| `parMaxWorkers` | Round and clamp to the existing 1–6 worker range |
| `truePosition.E/N/U` | Empty JSON null or a nonscalar/nonnumeric value becomes scalar `NaN` |
| `nmea.utcOffsetSeconds` | Canonical value wins; `bdtMinusUtc` is an alias only when the canonical field was omitted |
| `Frontend` | Resolved by `frontend/resolveFrontendSettings.m` after construction; an explicit mode wins over `EnablePB` |

The amplitude conversion is:

```matlab
digitalDb = thresholdDbm - usrp.scaleK - usrp.gain + 10*log10(samplingFreq);
thresholdAmplitude = 10^(digitalDb/20);
```

Acquisition and tracking thresholds retain their separate dBm defaults. Complete settings structures contain explicit digital thresholds and explicit search windows, so serialization preserves those values. If changing sampling rate/calibration should rederive them, start from a partial configuration or remove the corresponding derived fields before calling `initSettings` again. Arbitrary MATLAB-only objects and unknown custom array-shape conventions are outside the JSON transport contract; use JSON-representable configuration values.

No TF mode is enabled automatically. With no explicit `Frontend.mode`, the legacy `EnablePB` choice remains effective, including callers that edit `s.EnablePB` before running. With an explicit mode, change `s.Frontend.mode` to switch processing. TF v1 supports signed int8/int16 interleaved IQ, and resolves its FIR length from the final sample rate unless explicitly overridden. See [frontend usage](../upgrade_v020/USAGE.md) and the [parameter experiment report](../tf_parameter_grid/参数选择报告.md).

## Pipeline switches and result layout

| Control in the config | Fallback if absent | Additional condition |
|---|---|---|
| `doNavigation` | `true` | Acquisition and tracking must succeed |
| `doPlot` | `plotNavPost`, then `true` | Master switch; tracking export additionally needs `plotTracking` |
| `doNmea` | `nmea.enable`, then `true` | Navigation must produce a solution |
| `doBaiduMap` | `plotBaiduMap`, then `true` | `doPlot` and a navigation solution are also required |

These fallbacks are identical for JSON, partial structs and complete settings. Explicit `do*` fields take precedence. Boolean flags also accept numeric scalar truth values and UI true strings (`1`, `true`, `yes`, `on`). The settings wrapper's explicit name/value `do*` overrides take precedence over fields in the structure; an omitted wrapper option does not replace the field. In particular, an existing `settings.tag` is preserved unless an explicit wrapper tag overrides it.

Output directory precedence is the runner's `outDir` option, then `config.outDir`, then `<project>/results/ui/<tag>`. This replaces `settings.resultRoot` and `settings.tempdataSvPth` with the shared run layout:

```text
<outDir>/
  ui_config.json                 requested config + run controls/tag/output
  report.json                    stage, success/error and summary metadata
  ui_results.mat                 small UI/navigation product + effective settings
  run_B2a_<tag>.mat               full results, including plain tracking structs
  temp/                          tracking chunks
  figures/AcqResult/
  figures/trkResult/
  figures/navResult/
```

The runner also records the resolved controls, tag and destination in effective settings, so snapshot replay does not differ merely because a control was inferred on the first call. `ui_config.json` preserves requested inputs; the MAT files contain effective settings, including a capped duration. Use a new output directory for an independent run because matching product names can be overwritten.

`openBaiduBrowser` and `closeFigures` are execution options. Closing figures affects only figures newly created during this call; the MATLAB session and pre-existing figures remain open. `skipAcquisition=true` is currently unsupported by this runner and produces an acquisition-stage failure.

Configuration/preparation errors throw before the guarded processing stages. File-opening, acquisition, tracking and navigation exceptions after preparation return `report.ok=false` with an identifier and stage; the runner attempts to retain a lightweight `ui_results.mat`. Optional figure/NMEA export failures warn. Do not infer successful processing merely from the existence of an output folder or MAT file.

## Changes from the previous entry behavior

- Removed JSON-only field selection and its separate settings-finalization code; both transports now use the same constructor.
- Made JSON honor the same legacy plot/NMEA/map fallbacks as MATLAB settings.
- Applied all name/value fields instead of silently discarding fields outside a short parser list; merged partial nested options consistently.
- Derived omitted ADC thresholds and fine-code windows after final sampling/calibration overrides.
- Preserved wrapper tags and canonicalized run controls for snapshot replay.
- Made too-short files and malformed PRN text fail consistently before processing.

Explicit semiphysical configurations retain their supplied digital thresholds and FIR parameters. The defaults have not been changed to the experiment's recommended 800 kHz / 3 us.

## Validation

Targeted tests are in `tests/test_config_entrypoints.m`. They exercise JSON, raw struct, `initSettings(struct)`, and name/value construction with scalar/nested overrides; 25/30.69 MHz; int8/int16 IQ; exclusive TF/PB selection; digital/dBm precedence; loop aliases; PRN text/vectors; duration/skip geometry; worker capping; NMEA time aliases; null reference coordinates; wrapper overrides; and snapshot replay. Deliberately missing/tiny IF fixtures stop processing after settings have been prepared, allowing inspection of the actual effective settings without a long SDR run.

`tests/verify_config_entrypoint_if.m` independently runs the same five-second slice of case 4, PRN 11, through JSON and `initSettings(name/value) -> runFromSettings`. It compares effective settings, acquisition output and the full saved tracking structures, then checks 18 scientific/state fields against the corresponding prefix of the archived 715-second 800 kHz / 3 us experiment. Five seconds cover INIT and its transition to LONG; they do not validate post-warmup S4 accuracy.

```matlab
setupPaths;
r = runtests({'tests/test_config_entrypoints.m', ...
             'tests/test_tf_frontend.m', ...
             'tests/test_NH_stateMachine_reacq.m'});
assertSuccess(r);
test_batch_dir_for_one_settings;
verify_config_entrypoint_if(fullfile(pwd,'results','config_entrypoints','new_if_check'));
```

The real-IF check requires the existing source file and archived baseline described above, and refuses an existing output directory. Full logs/MATs remain in local `results/config_entrypoints/run_02/`.

Completed validation (2026-10-01, MATLAB R2026a):

- All **22 targeted tests passed**, with no failures or incomplete cases: 8 entry-point tests, 10 frontend tests, and 4 NH/reacquisition tests. See [test results](evidence/tests.json).
- Batch dry-run checks passed for 2 JSON-selected files and 3 recursively selected settings files. See [batch results](evidence/batch.json).
- Two actual **5,000 ms** runs on the same case-4 interference IF, PRN 11, 25 MHz int16 IQ, complex FIR **800 kHz / 3 us**, produced exactly equal effective settings (excluding the three destination fields), acquisition structures, and complete tracking structures. All 18 archived-prefix comparisons were also exactly equal. See [IF verification](evidence/entrypoint_if_summary.json) and [input configuration](evidence/input.json).
- `S4` and `S4_ori` contain no finite values during this short pre-warmup interval; equality here verifies transport/processing consistency, not finite S4 accuracy. Navigation was disabled in this single-satellite check, so it does not establish PVT equivalence from real navigation solutions.

The receiver frontend, acquisition and tracking algorithms and their experiment defaults were not changed in this work. The constructor/runner repairs above address configuration transport and replay. The [evidence manifest](evidence/manifest.json) records source and evidence hashes; runtime source hashes use UTF-8 text with LF line endings so Windows checkout line-ending conversion does not invalidate them.
