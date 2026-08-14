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

    projectRoot = fileparts(fileparts(mfilename('fullpath')));
    if ~isfield(p.Unmatched, 'resultRoot')
        settings.resultRoot = fullfile(projectRoot, 'results', 'ui', char(pipe.tag));
    end
    if ~isfield(p.Unmatched, 'tempdataSvPth')
        settings.tempdataSvPth = fullfile(settings.resultRoot, 'temp');
    end
    localPrepareUiLayout(settings.resultRoot);

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
        if pipe.saveResults
            localWriteUiProducts(results, settings, pipe, acqResults);
        end
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
                exportNmea(navSolutions, settings, ...
                    'trackResults', trackResults, 'eph', eph, ...
                    'outDir', settings.resultRoot);
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
                            'figures', 'trkResult');
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
                figDir = fullfile(settings.resultRoot, 'figures', 'navResult');
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
        writeUiResultsMat(fullfile(settings.resultRoot, 'ui_results.mat'), results);
        clear diskPayload
        localWriteUiProducts(results, settings, pipe, acqResults);
        fprintf('Saved results: %s\n', outFile);
    end

    fprintf('========== Processing complete ==========\n');
end

function localPrepareUiLayout(resultRoot)
    dirs = {resultRoot, fullfile(resultRoot, 'temp'), ...
        fullfile(resultRoot, 'figures'), ...
        fullfile(resultRoot, 'figures', 'AcqResult'), ...
        fullfile(resultRoot, 'figures', 'trkResult'), ...
        fullfile(resultRoot, 'figures', 'navResult')};
    for idx = 1:numel(dirs)
        if ~exist(dirs{idx}, 'dir'), mkdir(dirs{idx}); end
    end
end

function localWriteUiProducts(results, settings, pipe, acqResults)
    writeUiResultsMat(fullfile(settings.resultRoot, 'ui_results.mat'), results);
    config = settings;
    config.tag = char(pipe.tag);
    config.outDir = strrep(settings.resultRoot, '\', '/');
    config.doNavigation = logical(pipe.doNavigation);
    config.doPlot = logical(pipe.doPlot);
    if isfield(settings, 'nmea') && isstruct(settings.nmea) && ...
            isfield(settings.nmea, 'enable')
        config.doNmea = logical(settings.nmea.enable);
    else
        config.doNmea = true;
    end
    if isempty(pipe.openBaiduMap)
        config.doBaiduMap = isfield(settings, 'plotBaiduMap') && ...
            logical(settings.plotBaiduMap);
    else
        config.doBaiduMap = logical(pipe.openBaiduMap);
    end
    config.recovered = false;
    localWriteJson(fullfile(settings.resultRoot, 'ui_config.json'), config);

    report = struct('ok', true, 'stage', 'done', ...
        'outDir', settings.resultRoot, 'tag', char(pipe.tag), ...
        'errorIdentifier', '', 'error', '', 'nAcquired', 0, ...
        'figDir', fullfile(settings.resultRoot, 'figures'), ...
        'acqFigDir', fullfile(settings.resultRoot, 'figures', 'AcqResult'), ...
        'trkFigDir', fullfile(settings.resultRoot, 'figures', 'trkResult'), ...
        'navFigDir', fullfile(settings.resultRoot, 'figures', 'navResult'), ...
        'nmeaPath', fullfile(settings.resultRoot, 'pvt.nmea'), ...
        'navSummary', struct('nFixes', 0, 'meanLat', NaN, ...
        'meanLon', NaN, 'meanH', NaN));
    if isstruct(acqResults) && isfield(acqResults, 'carrFreq')
        report.nAcquired = nnz(acquisitionDetectedMask(acqResults));
    end
    nav = results.navSolutions;
    if isstruct(nav) && isfield(nav, 'latitude') && isfield(nav, 'longitude')
        ok = isfinite(nav.latitude) & isfinite(nav.longitude);
        report.navSummary.nFixes = nnz(ok);
        if any(ok)
            report.navSummary.meanLat = mean(nav.latitude(ok));
            report.navSummary.meanLon = mean(nav.longitude(ok));
            if isfield(nav, 'height')
                h = nav.height(ok); h = h(isfinite(h));
                if ~isempty(h), report.navSummary.meanH = mean(h); end
            end
        end
    end
    localWriteJson(fullfile(settings.resultRoot, 'report.json'), report);
end

function localWriteJson(path, value)
    try
        text = jsonencode(value, 'PrettyPrint', true);
    catch
        text = jsonencode(value);
    end
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0, error('run_B2a:WriteJson', 'Cannot write %s', path); end
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fwrite(fid, text, 'char');
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
