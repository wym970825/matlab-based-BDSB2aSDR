function smoke = smoke_acquisition(varargin)
%SMOKE_ACQUISITION Acquisition-only smoke test.
%
% Default: scan all BDS B2a PRNs 1..63, report peak metrics, pick best SV.
% Optional overrides forwarded to initSettings.

    setupPaths();

    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'fullSky', true, @islogical);
    addParameter(p, 'prnList', 1:63);
    parse(p, varargin{:});

    unmatched = namedargs2cell(p.Unmatched);
    if p.Results.fullSky
        list = p.Results.prnList;
    else
        list = []; % will use initSettings default
    end

    if isempty(list)
        settings = initSettings(unmatched{:}, ...
            'plotTracking', 0, ...
            'EnablePB', true);
    else
        settings = initSettings(unmatched{:}, ...
            'acqSatelliteList', list, ...
            'plotTracking', 0, ...
            'EnablePB', true);
    end

    % Acquisition only needs a few ms of data
    settings.msToProcess = max(settings.msToProcess, 10);

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() safeClose(fid)); %#ok<NASGU>

    t0 = tic;
    acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    elapsed = toc(t0);

    satList = settings.acqSatelliteList;
    cf = acqResults.carrFreq(:).';
    pm = acqResults.peakMetric(:).';
    acquired = isfinite(cf) & (cf ~= 0);

    fprintf('\n=== Acquisition smoke report (%.1f s) ===\n', elapsed);
    fprintf('Searched %d PRNs, acquired %d\n', numel(satList), nnz(acquired));
    fprintf('%-6s %-12s %-12s %-12s %-10s\n', ...
        'PRN', 'carrFreq', 'peakMetric', 'codePhase', 'weilPhase');
    for k = 1:numel(satList)
        if acquired(k)
            fprintf('%-6d %-12.2f %-12.3f %-12d %-10d\n', ...
                satList(k), cf(k), pm(k), acqResults.codePhase(k), ...
                acqResults.weilPhase(k));
        end
    end

    bestPrn = [];
    if any(acquired)
        pm2 = pm;
        pm2(~acquired) = -inf;
        [~, ib] = max(pm2);
        bestPrn = satList(ib);
        fprintf('Best PRN by peakMetric: %d (metric=%.3f)\n', bestPrn, pm(ib));
    end

    smoke = struct();
    smoke.settings   = settings;
    smoke.acqResults = acqResults;
    smoke.acquiredPrn = satList(acquired);
    smoke.bestPrn    = bestPrn;
    smoke.elapsed_s  = elapsed;

    outDir = fullfile(settings.resultRoot, 'smoke');
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    outFile = fullfile(outDir, sprintf('acq_%s.mat', ...
        string(datetime('now'), 'yyMMdd_HHmmss')));
    save(outFile, 'smoke', '-v7.3');
    fprintf('Saved: %s\n', outFile);
end

function safeClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
