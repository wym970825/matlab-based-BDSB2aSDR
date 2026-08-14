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
%   'saveTrackingFigures' (default false)
%   'openBaiduMap'  (default: use settings.plotBaiduMap)
%   'tag'           result file tag string

    setupPaths();

    % Split pipeline-only options from settings overrides
    p = inputParser;
    p.KeepUnmatched = true;
    addParameter(p, 'doNavigation', true, @islogical);
    addParameter(p, 'doPlot', true, @islogical);
    addParameter(p, 'saveResults', true, @islogical);
    addParameter(p, 'saveTrackingFigures', false, @islogical);
    addParameter(p, 'openBaiduMap', [], @(x) isempty(x) || islogical(x));
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

    if ~any(acquisitionDetectedMask(acqResults))
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
        % NMEA 0183 (GGA + GSV)
        if ~isempty(navSolutions) ...
                && (~isfield(settings, 'nmea') || ~isfield(settings.nmea, 'enable') ...
                    || logical(settings.nmea.enable))
            try
                nmeaDir = fullfile(settings.resultRoot, sprintf('nmea_%s', pipe.tag));
                exportNmea(navSolutions, settings, ...
                    'trackResults', trackResults, 'eph', eph, ...
                    'outDir', nmeaDir);
            catch ME
                warning('run_B2a:NMEA', 'NMEA export failed: %s', ME.message);
            end
        end
    end

    %% Plot ----------------------------------------------------------------
    if pipe.doPlot
        if settings.plotTracking && ~isempty(trackResults)
            activeIdx = find(arrayfun(@(c) c.PRN ~= 0, channel));
            if ~isempty(activeIdx)
                try
                    isLongTracking = settings.msToProcess > 60000;
                    if isLongTracking || pipe.saveTrackingFigures
                        trkFigDir = fullfile(settings.resultRoot, ...
                            sprintf('trkfigs_%s', pipe.tag));
                        exportTrackingFiguresSequential(trackResults, ...
                            settings, trkFigDir, ...
                            'ChannelIndices', activeIdx, ...
                            'Visible', false);
                    else
                        % Short interactive diagnostics retain the detailed
                        % legacy plots; long runs always use bounded export.
                        plotTracking_NHSMKF(activeIdx, trackResults, settings);
                    end
                catch ME
                    warning('run_B2a:PlotTrack', 'plotTracking failed: %s', ME.message);
                end
            end
        end
        if ~isempty(navSolutions)
            try
                figDir = fullfile(settings.resultRoot, sprintf('navfigs_%s', pipe.tag));
                navFigs = plotNavPost(navSolutions, settings, ...
                    'saveDir', figDir, ...
                    'doLegacy', false, ...
                    'openBaiduMap', pipe.openBaiduMap);
                closeFigureStruct(navFigs);
                drawnow;
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
        diskPayload.results = results;
        diskPayload.results.trackResults = trackResultsToStruct(trackResults);
        save(outFile, '-struct', 'diskPayload', '-v7.3');
        clear diskPayload
        fprintf('Saved results: %s\n', outFile);
    end

    fprintf('========== Processing complete ==========\n');
end

function closeFigureStruct(figs)
    if ~isstruct(figs), return; end
    names = fieldnames(figs);
    for idx = 1:numel(names)
        fig = figs.(names{idx});
        if ~isempty(fig) && all(isgraphics(fig))
            close(fig);
        end
    end
end

function safeClose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
