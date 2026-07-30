function results = run_B2a(varargin)
%RUN_B2A Main BDS-3 B2a SDR processing pipeline (refactored entry).
%
%   results = run_B2a()
%   results = run_B2a('msToProcess', 30000, 'acqSatelliteList', 24, ...)
%
% Stages: settings -> open IF -> acquire -> preRun -> track -> navigate -> plot
%
% Optional name-value pairs are forwarded to initSettings.
% Additional pipeline options:
%   'doNavigation'  (default true)
%   'doPlot'        (default true)
%   'saveResults'   (default true)
%   'tag'           result file tag string

    setupPaths();

    % Split pipeline-only options from settings overrides
    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'doNavigation', true, @islogical);
    addParameter(p, 'doPlot', true, @islogical);
    addParameter(p, 'saveResults', true, @islogical);
    addParameter(p, 'tag', string(datetime('now'), 'yyMMdd_HHmmss'), @(x)ischar(x)||isstring(x));
    parse(p, varargin{:});
    pipe = p.Results;

    unmatched = namedargs2cell(p.Unmatched);
    settings = initSettings(unmatched{:});

    fprintf('\n========== B2a Receiver (refactored) ==========\n');
    fprintf('Result root: %s\n', settings.resultRoot);
    fprintf('Temp track:  %s\n', settings.tempdataSvPth);

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() safeClose(fid));

    %% Acquisition ---------------------------------------------------------
    if settings.skipAcquisition == 0
        acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
    else
        error('run_B2a:SkipAcqNotSupported', ...
            'skipAcquisition requires preloaded acqResults (not implemented).');
    end

    if ~any(isfinite(acqResults.carrFreq) & (acqResults.carrFreq ~= 0))
        disp('No GNSS signals detected — stopping.');
        results = struct('settings', settings, 'acqResults', acqResults, ...
            'trackResults', [], 'navSolutions', [], 'eph', []);
        return;
    end

    channel = preRun2(acqResults, settings);
    showChannelStatus(channel, settings);

    %% Tracking ------------------------------------------------------------
    t0 = datetime('now');
    fprintf('   Tracking started at %s\n', string(t0, 'yyyy-MM-dd HH:mm:ss'));
    [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
    fprintf('   Tracking finished (elapsed %s)\n', string(datetime('now') - t0));

    %% Navigation ----------------------------------------------------------
    navSolutions = [];
    eph = [];
    if pipe.doNavigation
        fprintf('   Calculating navigation solutions...\n');
        [navSolutions, eph] = runNavigation(trackResults, settings);
        fprintf('   Navigation complete.\n');
    end

    %% Plot ----------------------------------------------------------------
    if pipe.doPlot
        if settings.plotTracking && ~isempty(trackResults)
            activeIdx = find(arrayfun(@(c) c.PRN ~= 0, channel));
            if ~isempty(activeIdx)
                try
                    plotTracking_NHSMKF(activeIdx, trackResults, settings);
                catch ME
                    warning('run_B2a:PlotTrack', 'plotTracking failed: %s', ME.message);
                end
            end
        end
        if ~isempty(navSolutions)
            try
                figDir = fullfile(settings.resultRoot, sprintf('navfigs_%s', pipe.tag));
                plotNavPost(navSolutions, settings, ...
                    'saveDir', figDir, ...
                    'doLegacy', true, ...
                    'openBaiduMap', []);  % honor settings.plotBaiduMap
            catch ME
                warning('run_B2a:PlotNav', 'plotNavPost failed: %s', ME.message);
                try
                    plotNavigation(navSolutions, settings);
                catch ME2
                    warning('run_B2a:PlotNavLegacy', '%s', ME2.message);
                end
            end
        end
    end

    results = struct( ...
        'settings', settings, ...
        'acqResults', acqResults, ...
        'channel', channel, ...
        'trackResults', trackResults, ...
        'navSolutions', navSolutions, ...
        'eph', eph);

    if pipe.saveResults
        outFile = fullfile(settings.resultRoot, sprintf('run_B2a_%s.mat', pipe.tag));
        save(outFile, 'results', '-v7.3');
        fprintf('Saved results: %s\n', outFile);
    end

    fprintf('========== Processing complete ==========\n');
end

function safeClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
