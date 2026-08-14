function report = compare_dll_pullin_bandwidth(varargin)
%COMPARE_DLL_PULLIN_BANDWIDTH Controlled single-PRN DLL pull-in comparison.
%
%   report = compare_dll_pullin_bandwidth()
%   report = compare_dll_pullin_bandwidth('BandwidthsHz', [20 12 10])
%
% Acquisition is performed once. Each tracking run starts from the same
% acquisition handoff and changes only dllNoiseBandwidth_pull.

    setupPaths();

    p = inputParser;
    addParameter(p, 'PRN', 45, @(x) isnumeric(x) && isscalar(x));
    addParameter(p, 'BandwidthsHz', [20 12 10], ...
        @(x) isnumeric(x) && isvector(x) && all(x > 0));
    addParameter(p, 'msToProcess', 6000, ...
        @(x) isnumeric(x) && isscalar(x) && x >= 4000);
    addParameter(p, 'SaveTrackResults', true, @islogical);
    parse(p, varargin{:});
    opts = p.Results;

    stamp = char(string(datetime('now'), 'yyMMdd_HHmmss'));
    outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
        'results', ['dll_pullin_compare_' stamp]);
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    settings = initSettings( ...
        'msToProcess', opts.msToProcess, ...
        'acqSatelliteList', opts.PRN, ...
        'numberOfChannels', 1, ...
        'plotTracking', 0, ...
        'useParfor', false);

    % Hold FLL behavior fixed at the moderate tuning point. The comparison
    % must not inherit the aggressive 10/6-Hz, 300-ms experiment.
    settings.FLL.errThInitOn_Hz = 15;
    settings.FLL.errThInitOff_Hz = 10;
    settings.FLL.errThLongOn_Hz = 15;
    settings.FLL.errThLongOff_Hz = 10;
    settings.FLL.N_on = 3;
    settings.FLL.N_off = 10;
    settings.FLL.gainInit = 0.003;
    settings.FLL.gainLong = 0.005;
    settings.FLLinitT = 150;

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() localClose(fid));
    acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    channel0 = preRun2(acqResults, settings);
    active = find([channel0.PRN] == opts.PRN, 1);
    if isempty(active)
        error('compare_dll_pullin_bandwidth:NotAcquired', ...
            'PRN %d was not acquired.', opts.PRN);
    end
    channel0 = channel0(active);

    bandwidths = unique(double(opts.BandwidthsHz(:).'), 'stable');
    rows = repmat(localEmptyRow(), numel(bandwidths), 1);
    trackResults = cell(numel(bandwidths), 1);

    fprintf('\nDLL pull-in A/B: PRN %d, %d ms, stable DLL %.1f Hz\n', ...
        opts.PRN, settings.msToProcess, settings.dllNoiseBandwidth_stab);
    for idx = 1:numel(bandwidths)
        runSettings = settings;
        runSettings.dllNoiseBandwidth_pull = bandwidths(idx);
        runSettings.tempdataSvPth = fullfile(outDir, ...
            sprintf('temp_dll_%gHz', bandwidths(idx)));
        if ~exist(runSettings.tempdataSvPth, 'dir')
            mkdir(runSettings.tempdataSvPth);
        end

        fprintf('\n[%d/%d] DLL pull-in %.1f Hz\n', ...
            idx, numel(bandwidths), bandwidths(idx));
        started = tic;
        [trackResults{idx}, ~] = trackOneChannel( ...
            channel0, runSettings, 1, 1);
        rows(idx) = localSummarize(trackResults{idx}, bandwidths(idx), ...
            toc(started));
        localPrint(rows(idx));
    end

    summary = struct2table(rows);
    report = struct('settings', settings, 'options', opts, ...
        'acqResults', acqResults, 'channel', channel0, ...
        'summary', summary, 'outputDir', outDir);
    if opts.SaveTrackResults
        report.trackResults = trackResults;
    end

    save(fullfile(outDir, 'dll_pullin_comparison.mat'), 'report', '-v7.3');
    writetable(summary, fullfile(outDir, 'dll_pullin_summary.csv'));
    fprintf('\nSaved DLL comparison: %s\n', outDir);
    disp(summary);
end

function row = localSummarize(tr, bandwidthHz, elapsedSec)
    row = localEmptyRow();
    row.bandwidthHz = bandwidthHz;
    row.elapsedSec = elapsedSec;
    if isempty(tr) || tr.PRN == 0, return; end

    N = min([numel(tr.trk_state), numel(tr.dllDiscrFilt), ...
        numel(tr.pllDiscrFilt), numel(tr.fllAided)]);
    state = double(tr.trk_state(1:N));
    dllNco = abs(double(tr.dllDiscrFilt(1:N)));
    pllNco = abs(double(tr.pllDiscrFilt(1:N)));
    fllAided = logical(tr.fllAided(1:N));
    validDll = dllNco(isfinite(dllNco));
    validPll = pllNco(isfinite(pllNco));
    isLong = state == 3 | state == 4;
    isReacq = state == 9;
    firstLong = find(isLong, 1);

    row.longPct = 100 * mean(isLong);
    row.reacqPct = 100 * mean(isReacq);
    row.fllAidedPct = 100 * mean(fllAided);
    if ~isempty(firstLong), row.firstLongSec = firstLong / 1000; end
    if ~isempty(validDll)
        row.dllP95Hz = prctile(validDll, 95);
        row.dllMaxHz = max(validDll);
    end
    if ~isempty(validPll)
        row.pllP95Hz = prctile(validPll, 95);
        row.pllMaxHz = max(validPll);
    end
end

function row = localEmptyRow()
    row = struct('bandwidthHz', NaN, 'firstLongSec', NaN, ...
        'longPct', NaN, 'reacqPct', NaN, 'fllAidedPct', NaN, ...
        'dllP95Hz', NaN, 'dllMaxHz', NaN, ...
        'pllP95Hz', NaN, 'pllMaxHz', NaN, 'elapsedSec', NaN);
end

function localPrint(row)
    fprintf(['  first LONG %.3f s | LONG %.1f%% | REACQ %.1f%% | ' ...
        'FLL %.1f%% | DLL p95/max %.2f/%.2f Hz | ' ...
        'PLL p95/max %.2f/%.2f Hz | wall %.1f s\n'], ...
        row.firstLongSec, row.longPct, row.reacqPct, row.fllAidedPct, ...
        row.dllP95Hz, row.dllMaxHz, row.pllP95Hz, row.pllMaxHz, ...
        row.elapsedSec);
end

function localClose(fid)
    if ~isempty(fid) && fid > 0
        try
            fclose(fid);
        catch
        end
    end
end
