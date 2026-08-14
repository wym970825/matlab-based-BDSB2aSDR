function report = monteCarloAcquisitionAllPrns(varargin)
%MONTECARLOACQUISITIONALLPRNS End-to-end B2a acquisition Monte Carlo.
%
% The default run covers PRN 1:60 with three randomized signal trials and
% one noise-only trial per PRN. Signals cross a primary-code boundary in
% every 1-ms observation, so pilot secondary-code and data-symbol changes
% exercise the acquisition flip logic.

    setupPaths();
    p = inputParser;
    addParameter(p, 'PRNs', 1:60, ...
        @(x) isnumeric(x) && isvector(x) && all(x >= 1 & x <= 63));
    addParameter(p, 'TrialsPerPrn', 3, ...
        @(x) isnumeric(x) && isscalar(x) && x >= 1);
    addParameter(p, 'NoiseTrialsPerPrn', 1, ...
        @(x) isnumeric(x) && isscalar(x) && x >= 0);
    addParameter(p, 'CNoRangeDbHz', [43 49], ...
        @(x) isnumeric(x) && numel(x) == 2 && x(2) >= x(1));
    addParameter(p, 'Seed', 20260813, ...
        @(x) isnumeric(x) && isscalar(x));
    addParameter(p, 'UseParallel', true, @islogical);
    addParameter(p, 'MaxWorkers', 6, ...
        @(x) isnumeric(x) && isscalar(x) && x >= 1);
    addParameter(p, 'SaveCaseResults', false, @islogical);
    parse(p, varargin{:});
    opts = p.Results;
    opts.PRNs = unique(round(double(opts.PRNs(:).')), 'stable');
    opts.TrialsPerPrn = round(opts.TrialsPerPrn);
    opts.NoiseTrialsPerPrn = round(opts.NoiseTrialsPerPrn);
    opts.MaxWorkers = round(opts.MaxWorkers);

    stamp = char(string(datetime('now'), 'yyMMdd_HHmmss'));
    root = fileparts(fileparts(mfilename('fullpath')));
    outDir = fullfile(root, 'results', ['acq_monte_carlo_' stamp]);
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    settings = localSettings();
    rows = repmat(localEmptyRow(), 0, 1);
    started = tic;

    fprintf(['Acquisition Monte Carlo: %d PRNs x %d signal trial(s) + ' ...
        '%d noise trial(s), seed=%d\n'], numel(opts.PRNs), ...
        opts.TrialsPerPrn, opts.NoiseTrialsPerPrn, opts.Seed);

    for trial = 1:opts.TrialsPerPrn
        trialRows = localRunBatch(opts.PRNs, trial, false, opts, settings);
        rows = [rows; trialRows(:)]; %#ok<AGROW>
        localCheckpoint(rows, opts, settings, outDir, toc(started));
        passed = [trialRows.passed];
        fprintf('  signal trial %d/%d: %d/%d passed\n', ...
            trial, opts.TrialsPerPrn, nnz(passed), numel(passed));
    end

    for trial = 1:opts.NoiseTrialsPerPrn
        trialRows = localRunBatch(opts.PRNs, trial, true, opts, settings);
        rows = [rows; trialRows(:)]; %#ok<AGROW>
        localCheckpoint(rows, opts, settings, outDir, toc(started));
        passed = [trialRows.passed];
        fprintf('  noise trial %d/%d: %d/%d correctly rejected\n', ...
            trial, opts.NoiseTrialsPerPrn, nnz(passed), numel(passed));
    end

    cases = struct2table(rows);
    signalCases = ~cases.noiseOnly;
    noiseCases = cases.noiseOnly;
    perPrn = localPerPrnSummary(cases, opts.PRNs);
    summary = struct( ...
        'nCases', height(cases), ...
        'nSignalCases', nnz(signalCases), ...
        'nNoiseCases', nnz(noiseCases), ...
        'signalPassRate', mean(cases.passed(signalCases)), ...
        'detectionRate', mean(cases.detected(signalCases)), ...
        'codePassRate', mean(cases.codePassed(signalCases)), ...
        'frequencyPassRate', mean(cases.frequencyPassed(signalCases)), ...
        'weilPatternPassRate', mean(cases.weilPatternPassed(signalCases)), ...
        'falseAlarmRate', mean(cases.detected(noiseCases)), ...
        'elapsedSec', toc(started));

    report = struct('options', opts, 'settings', settings, ...
        'summary', summary, 'perPrn', perPrn, 'outputDir', outDir);
    if opts.SaveCaseResults
        report.cases = cases;
    end
    save(fullfile(outDir, 'monte_carlo_report.mat'), ...
        'report', 'cases', '-v7.3');
    writetable(cases, fullfile(outDir, 'monte_carlo_cases.csv'));
    writetable(perPrn, fullfile(outDir, 'monte_carlo_per_prn.csv'));
    localWriteSummary(summary, perPrn, outDir);

    fprintf(['Monte Carlo complete in %.1f s: signal pass %.2f%%, ' ...
        'detection %.2f%%, false alarm %.2f%%\nSaved: %s\n'], ...
        summary.elapsedSec, 100 * summary.signalPassRate, ...
        100 * summary.detectionRate, 100 * summary.falseAlarmRate, outDir);
end

function rows = localRunBatch(prns, trial, noiseOnly, opts, settings)
    rows = repmat(localEmptyRow(), numel(prns), 1);
    if opts.UseParallel && license('test', 'Distrib_Computing_Toolbox')
        pool = gcp('nocreate');
        if isempty(pool)
            parpool('Processes', min(opts.MaxWorkers, numel(prns)));
        end
        parfor (idx = 1:numel(prns), opts.MaxWorkers)
            rows(idx) = localRunCase(prns(idx), trial, noiseOnly, opts, settings);
        end
    else
        for idx = 1:numel(prns)
            rows(idx) = localRunCase(prns(idx), trial, noiseOnly, opts, settings);
        end
    end
end

function row = localRunCase(prn, trial, noiseOnly, opts, settings)
    row = localEmptyRow();
    row.PRN = prn;
    row.trial = trial;
    row.noiseOnly = noiseOnly;
    seed = opts.Seed + 10000 * double(noiseOnly) + 100 * trial + prn;
    stream = RandStream('mt19937ar', 'Seed', seed);

    n = settings.codeLength;
    nMs = settings.coarseNoncohMs;
    codeOffset = randi(stream, [0, n - 1]);
    weilStart = randi(stream, [0, 99]);
    dopplerHz = localRandomDoppler(stream, settings);
    cno = opts.CNoRangeDbHz(1) + diff(opts.CNoRangeDbHz) * rand(stream);
    pilotPolarity = 2 * randi(stream, [0, 1]) - 1;
    dataSymbols = 2 * randi(stream, [0, 1], 1, nMs + 1) - 1;

    row.trueCodePhase = codeOffset + 1;
    row.trueDopplerHz = dopplerHz;
    row.trueWeilPhase = mod(weilStart + nMs - settings.fineNoncohMs - 1, 100);
    row.cnoDbHz = cno;

    if noiseOnly
        signal = complex(zeros(1, nMs * n));
    else
        signal = localSignal(prn, settings, codeOffset, weilStart, ...
            dopplerHz, cno, pilotPolarity, dataSymbols);
    end
    noise = (randn(stream, size(signal)) + ...
        1i * randn(stream, size(signal))) / sqrt(2);
    signal = signal + noise;

    caseSettings = settings;
    caseSettings.acqSatelliteList = prn;
    started = tic;
    result = acquisition_robust_v2fft(signal, caseSettings, ...
        'STA', 'SING', 'PRN', prn, 'ISSILENT', true);
    row.elapsedSec = toc(started);
    row.peakMetric = result.peakMetric;
    row.detected = any(acquisitionDetectedMask(result));

    if noiseOnly
        row.passed = ~row.detected;
        return;
    end
    if ~row.detected, return; end

    row.estimatedCodePhase = result.codePhase;
    row.estimatedCarrierHz = result.carrFreq;
    row.estimatedWeilPhase = result.weilPhase;
    row.codeErrorSamples = localCircularError( ...
        result.codePhase, row.trueCodePhase, n);
    row.frequencyErrorHz = result.carrFreq + dopplerHz;
    row.codePassed = row.codeErrorSamples <= 2;
    row.frequencyPassed = abs(row.frequencyErrorHz) <= ...
        max(settings.fineStepHz, 0.5 * settings.acqStep);

    weil = GenWeil(prn);
    truth = weil(mod(row.trueWeilPhase + ...
        (0:settings.fineNoncohMs - 1), 100) + 1);
    estimate = weil(mod(result.weilPhase + ...
        (0:settings.fineNoncohMs - 1), 100) + 1);
    row.weilPatternPassed = isequal(truth, estimate) || isequal(truth, -estimate);
    row.passed = row.detected && row.codePassed && ...
        row.frequencyPassed && row.weilPatternPassed;
end

function signal = localSignal(prn, settings, codeOffset, weilStart, ...
        dopplerHz, cnoDbHz, pilotPolarity, dataSymbols)
    n = settings.codeLength;
    nMs = settings.coarseNoncohMs;
    pilot = circshift(generateB2aPilotCode(prn, settings), [0 codeOffset]);
    data = circshift(generateB2aDataCode(prn), [0 codeOffset]);
    weil = GenWeil(prn);
    amplitude = sqrt(10^(cnoDbHz / 10) * 1e-3 / n);
    signal = complex(zeros(1, nMs * n));

    for msIdx = 1:nMs
        pilotSigns = [ ...
            weil(mod(weilStart + msIdx - 2, 100) + 1) * ...
                ones(1, codeOffset), ...
            weil(mod(weilStart + msIdx - 1, 100) + 1) * ...
                ones(1, n - codeOffset)];
        dataSigns = [dataSymbols(msIdx) * ones(1, codeOffset), ...
            dataSymbols(msIdx + 1) * ones(1, n - codeOffset)];
        idx = (msIdx - 1) * n + (1:n);
        signal(idx) = amplitude * ( ...
            pilotPolarity * pilotSigns .* pilot + ...
            1i * dataSigns .* data);
    end
    time = (0:numel(signal) - 1) / settings.samplingFreq;
    signal = signal .* exp(1i * 2 * pi * dopplerHz * time);
end

function doppler = localRandomDoppler(stream, settings)
    margin = settings.acqStep;
    lower = -settings.acqSearchBand + margin;
    upper = settings.acqSearchBand - margin;
    doppler = lower + (upper - lower) * rand(stream);
end

function error = localCircularError(actual, expected, period)
    error = abs(double(actual) - double(expected));
    error = min(error, period - error);
end

function settings = localSettings()
    settings = struct( ...
        'samplingFreq', 10.23e6, ...
        'codeFreqBasis', 10.23e6, ...
        'codeLength', 10230, ...
        'carrFreqBasis', 1176.45e6, ...
        'IF', 0, ...
        'acqSearchBand', 2000, ...
        'acqStep', 200, ...
        'acqThreshold', 1.4, ...
        'coarseNoncohMs', 5, ...
        'acqFlipSegments', 8, ...
        'fineNoncoh', 3, ...
        'fineNoncohMs', 3, ...
        'fineStepHz', 10, ...
        'fineSearchInitialHalfSpanHz', 200, ...
        'fineSearchMaxHalfSpanHz', 800, ...
        'fineCodeSearchHalfWinSamples', 2, ...
        'acqSatelliteList', 1:60);
end

function row = localEmptyRow()
    row = struct( ...
        'PRN', NaN, 'trial', NaN, 'noiseOnly', false, ...
        'cnoDbHz', NaN, 'trueCodePhase', NaN, ...
        'estimatedCodePhase', NaN, 'codeErrorSamples', NaN, ...
        'trueDopplerHz', NaN, 'estimatedCarrierHz', NaN, ...
        'frequencyErrorHz', NaN, 'trueWeilPhase', NaN, ...
        'estimatedWeilPhase', NaN, 'peakMetric', NaN, ...
        'detected', false, 'codePassed', false, ...
        'frequencyPassed', false, 'weilPatternPassed', false, ...
        'passed', false, 'elapsedSec', NaN);
end

function localCheckpoint(rows, opts, settings, outDir, elapsedSec)
    checkpoint = struct('options', opts, 'settings', settings, ...
        'rows', rows, 'elapsedSec', elapsedSec);
    save(fullfile(outDir, 'checkpoint.mat'), 'checkpoint', '-v7.3');
end

function summary = localPerPrnSummary(cases, prns)
    summary = table('Size', [numel(prns), 7], ...
        'VariableTypes', {'double', 'double', 'double', 'double', ...
        'double', 'double', 'double'}, ...
        'VariableNames', {'PRN', 'SignalCases', 'SignalPassRate', ...
        'DetectionRate', 'MaxCodeErrorSamples', ...
        'MaxAbsFrequencyErrorHz', 'FalseAlarmRate'});
    for idx = 1:numel(prns)
        signal = cases.PRN == prns(idx) & ~cases.noiseOnly;
        noise = cases.PRN == prns(idx) & cases.noiseOnly;
        summary.PRN(idx) = prns(idx);
        summary.SignalCases(idx) = nnz(signal);
        summary.SignalPassRate(idx) = mean(cases.passed(signal));
        summary.DetectionRate(idx) = mean(cases.detected(signal));
        summary.MaxCodeErrorSamples(idx) = max(cases.codeErrorSamples(signal));
        summary.MaxAbsFrequencyErrorHz(idx) = ...
            max(abs(cases.frequencyErrorHz(signal)));
        if any(noise)
            summary.FalseAlarmRate(idx) = mean(cases.detected(noise));
        else
            summary.FalseAlarmRate(idx) = NaN;
        end
    end
end

function localWriteSummary(summary, perPrn, outDir)
    fid = fopen(fullfile(outDir, 'summary.txt'), 'w');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid));
    fprintf(fid, 'B2a acquisition Monte Carlo\n');
    fprintf(fid, 'Cases: %d (%d signal, %d noise)\n', ...
        summary.nCases, summary.nSignalCases, summary.nNoiseCases);
    fprintf(fid, 'Signal pass rate: %.4f\n', summary.signalPassRate);
    fprintf(fid, 'Detection rate: %.4f\n', summary.detectionRate);
    fprintf(fid, 'Code pass rate: %.4f\n', summary.codePassRate);
    fprintf(fid, 'Frequency pass rate: %.4f\n', summary.frequencyPassRate);
    fprintf(fid, 'Weil-pattern pass rate: %.4f\n', ...
        summary.weilPatternPassRate);
    fprintf(fid, 'False-alarm rate: %.4f\n', summary.falseAlarmRate);
    fprintf(fid, 'Elapsed seconds: %.1f\n', summary.elapsedSec);
    failed = perPrn.PRN(perPrn.SignalPassRate < 1 | ...
        perPrn.FalseAlarmRate > 0);
    fprintf(fid, 'PRNs with any failed case: %s\n', mat2str(failed.'));
end
