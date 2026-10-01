function report = runFromJsonConfig(jsonPath, varargin)
%RUNFROMJSONCONFIG Run the B2a receiver from JSON or MATLAB settings.
%
%   report = runFromJsonConfig(jsonPath)
%   report = runFromJsonConfig(settingsStruct, 'outDir', outputFolder)
%
% INPUT: jsonPath names a JSON object; settingsStruct is a scalar partial or
% complete configuration (for example, initSettings(...)). Both are passed
% through the SAME initSettings constructor and resolveFrontendSettings.
% Nested overrides, derived values and file-duration limits therefore do
% not depend on the input transport. No MATLAB desktop is required.
%
% PIPELINE CONTROLS in the configuration:
%   doNavigation : run navigation after tracking (default true).
%   doPlot       : master figure/export switch (fallback plotNavPost).
%   doNmea       : allow NMEA export (fallback nmea.enable); needs navigation.
%   doBaiduMap   : allow the map (fallback plotBaiduMap); also needs doPlot.
% Explicit do* values take precedence; absent legacy switches default true.
% plotTracking additionally controls tracking-figure export under doPlot.
%
% EXECUTION OPTIONS (name/value pairs, not receiver algorithm settings):
%   outDir           : overrides config.outDir; otherwise results/ui/<tag>.
%   openBaiduBrowser : open the generated map in a browser (default true).
%   closeFigures     : close only figures created by this run (default false).
% config.tag supplies filenames; otherwise use the current local timestamp.
%
% OUTPUT: report.ok/stage/errorIdentifier/error describe execution. Invalid
% configuration/preparation throws; acquisition/tracking/navigation failures
% after preparation return report.ok=false. Optional plot/NMEA failures warn.
% Output includes ui_config.json (requested input plus resolved run controls),
% report.json (status), ui_results.mat (lightweight UI product), and on success
% run_B2a_<tag>.mat (full results.settings/acqResults/channel/trackResults/nav).
% Effective settings, including capped duration, live in the MAT products.
% Existing output filenames may be overwritten: use a fresh folder for an
% independent experiment. This function does not close the MATLAB session.
%
% Relative documentation: ../docs/config_entrypoints/README.md
% Frontend details:       ../docs/upgrade_v020/USAGE.md
% See also initSettings, runFromSettings, resolveFrontendSettings.

    setupPaths();

    p = inputParser;
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'openBaiduBrowser', true, @localLogicalScalar);
    addParameter(p, 'closeFigures', false, @localLogicalScalar);
    parse(p, varargin{:});

    % Decode only the transport here. A MATLAB struct and the same JSON
    % object must reach initSettings unchanged; neither gets a whitelist.
    if isstruct(jsonPath)
        if ~isscalar(jsonPath)
            error('runFromJsonConfig:BadSettings', 'Settings input must be a scalar struct');
        end
        raw = jsonPath;
    else
        jsonPath = char(jsonPath);
        if ~isfile(jsonPath)
            error('runFromJsonConfig:Missing', 'Config not found: %s', jsonPath);
        end
        raw = jsondecode(fileread(jsonPath));
        if ~isstruct(raw) || ~isscalar(raw)
            error('runFromJsonConfig:BadJson', 'JSON root must be an object');
        end
    end

    % Explicit do* controls win over their legacy settings counterparts.
    % Use the same fallback for JSON, partial structs and complete settings.
    doPlotDefault = localFlag(raw, 'plotNavPost', true);
    doNmeaDefault = localNestedFlag(raw, 'nmea', 'enable', true);
    doBaiduDefault = localFlag(raw, 'plotBaiduMap', true);
    doNav   = localFlag(raw, 'doNavigation', true);
    doPlot  = localFlag(raw, 'doPlot', doPlotDefault);
    doNmea  = localFlag(raw, 'doNmea', doNmeaDefault);
    doBaidu = localFlag(raw, 'doBaiduMap', doBaiduDefault);
    tag = localStr(raw, 'tag', char(string(datetime('now'), 'yyMMdd_HHmmss')));

    % Output layout is run-scoped for both entry points. resultRoot and
    % tempdataSvPth from the configuration are replaced by this layout.
    outDir = char(p.Results.outDir);
    if isempty(outDir)
        outDir = localStr(raw, 'outDir', '');
    end
    if isempty(outDir)
        root = fileparts(fileparts(mfilename('fullpath')));
        outDir = fullfile(root, 'results', 'ui', tag);
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    figDir = fullfile(outDir, 'figures');
    acqFigDir = fullfile(figDir, 'AcqResult');
    trkFigDir = fullfile(figDir, 'trkResult');
    navFigDir = fullfile(figDir, 'navResult');
    tempDir = fullfile(outDir, 'temp');
    if ~exist(tempDir, 'dir'), mkdir(tempDir); end
    if ~exist(figDir, 'dir'), mkdir(figDir); end
    if ~exist(acqFigDir, 'dir'), mkdir(acqFigDir); end
    if ~exist(trkFigDir, 'dir'), mkdir(trkFigDir); end
    if ~exist(navFigDir, 'dir'), mkdir(navFigDir); end

    % Central construction handles nested defaults, explicit overrides,
    % derived fields and duration limits for every configuration transport.
    settings = initSettings(raw);
    settings = resolveFrontendSettings(settings);
    settings.resultRoot = outDir;
    settings.tempdataSvPth = tempDir;
    % Canonical run metadata also makes ui_config.json replay independent of
    % whether a flag was originally explicit, inferred or absent.
    settings.outDir = outDir;
    settings.tag = tag;
    settings.doNavigation = doNav;
    settings.doPlot = doPlot;
    settings.doNmea = doNmea;
    settings.doBaiduMap = doBaidu;
    settings.plotNavPost = doPlot;
    settings.plotBaiduMap = doBaidu && doPlot;
    if ~isfield(settings, 'nmea') || ~isstruct(settings.nmea)
        settings.nmea = struct('enable', doNmea);
    end
    settings.nmea.enable = doNmea;
    % Keep a replayable configuration next to every result, including calls
    % made directly with a MATLAB settings struct.
    configSnapshot = raw;
    configSnapshot.outDir = strrep(outDir, '\', '/');
    configSnapshot.tag = tag;
    configSnapshot.doNavigation = doNav;
    configSnapshot.doPlot = doPlot;
    configSnapshot.doNmea = doNmea;
    configSnapshot.doBaiduMap = doBaidu;
    try
        localWriteJson(fullfile(outDir, 'ui_config.json'), configSnapshot);
    catch ME
        warning('runFromJsonConfig:ConfigSnapshot', ...
            'Could not write ui_config.json: %s', ME.message);
    end
    figuresBefore = [];
    if p.Results.closeFigures
        figuresBefore = findall(groot, 'Type', 'figure');
    end
    figureCleaner = onCleanup(@() localCloseNewFigures( ...
        figuresBefore, p.Results.closeFigures));

    fprintf('\n========== B2a UI pipeline ==========\n');
    fprintf('outDir      = %s\n', outDir);
    fprintf('IF          = %s\n', fullfile(settings.filePath, settings.fileName));
    fprintf('msToProcess = %g\n', settings.msToProcess);
    fprintf('acqList     = %s\n', mat2str(settings.acqSatelliteList));
    fprintf('nav/plot/nmea/baidu = %d/%d/%d/%d\n', doNav, doPlot, doNmea, doBaidu);

    % Publish a small status document between stages. requestedMs is the
    % caller's request; effectiveMs reflects integer rounding/file capping.
    report = struct();
    report.ok = false;
    report.outDir = outDir;
    report.figDir = figDir;
    report.acqFigDir = acqFigDir;
    report.trkFigDir = trkFigDir;
    report.navFigDir = navFigDir;
    report.tag = tag;
    report.frontend = settings.Frontend;
    report.softwareVersion = strtrim(fileread(fullfile(fileparts(fileparts(mfilename('fullpath'))),'VERSION')));
    report.stage = 'start';
    report.errorIdentifier = '';
    report.error = '';
    report.nmeaPath = '';
    report.nAcquired = 0;
    report.requestedMs = settings.msToProcess;
    if isfield(raw, 'msToProcess'), report.requestedMs = raw.msToProcess; end
    report.effectiveMs = settings.msToProcess;
    report.navSummary = struct('nFixes', 0, 'meanLat', NaN, 'meanLon', NaN, 'meanH', NaN);

    navSolutions = [];
    eph = [];
    acqResults = [];
    channel = [];
    try
        [fid, dataAdaptCoeff] = openIfFile(settings);
        cleaner = onCleanup(@() localClose(fid));

        %% Acquisition: all entries use the same file origin and frontend.
        report.stage = 'acquisition';
        writeReportJson(fullfile(outDir, 'report.json'), report);
        fprintf('--- Acquisition ---\n');
        if settings.skipAcquisition
            error('runFromJsonConfig:SkipAcq', ...
                'skipAcquisition=true is not supported by this runner');
        end
        acqResults = runAcquisition(fid, settings, dataAdaptCoeff);
        nAcq = 0;
        if isfield(acqResults, 'carrFreq')
            nAcq = nnz(acquisitionDetectedMask(acqResults));
        end
        report.nAcquired = nAcq;
        fprintf('Acquired SV count: %d\n', nAcq);
        if doPlot
            localExportAcquisitionFigure(acqResults, settings, acqFigDir);
        end
        if nAcq < 1
            error('runFromJsonConfig:NoAcq', 'No GNSS signals detected');
        end

        channel = preRun2(acqResults, settings);
        showChannelStatus(channel, settings);

        %% Tracking: retain native logical sample positions and metadata.
        report.stage = 'tracking';
        writeReportJson(fullfile(outDir, 'report.json'), report);
        fprintf('--- Tracking ---\n');
        t0 = datetime('now');
        [trackResults, channel] = tracking2_v6_fix2(fid, channel, settings);
        activeTracks = trackResults(arrayfun(@(tr) tr.PRN > 0, trackResults));
        report.trackingSummary = arrayfun(@(tr) struct('PRN', tr.PRN, ...
            'recordedMs', numel(tr.I_P), ...
            'finiteMs', nnz(isfinite(tr.I_P) & isfinite(tr.absoluteSample)), ...
            'reacqMs', nnz(tr.trk_state == 9)), activeTracks);
        fprintf('Tracking done (%s)\n', char(string(datetime('now') - t0)));
        if doPlot && isfield(settings, 'plotTracking') && ...
                logical(settings.plotTracking) && ~isempty(trackResults)
            activeIdx = find(arrayfun(@(c) localChannelPrn(c) > 0, channel));
            if ~isempty(activeIdx)
                trackingReport = exportTrackingFiguresSequential( ...
                    trackResults, settings, trkFigDir, ...
                    'ChannelIndices', activeIdx, 'Visible', false);
                report.trackingFigures = trackingReport.figureFiles;
            end
        end

        %% Navigation: optional; no navigation also means no NMEA export.
        if doNav
            report.stage = 'navigation';
            writeReportJson(fullfile(outDir, 'report.json'), report);
            fprintf('--- Navigation ---\n');
            [navSolutions, eph] = runNavigation(trackResults, settings);
            if doNmea && ~isempty(navSolutions)
                try
                    report.nmeaPath = exportNmea(navSolutions, settings, ...
                        'trackResults', trackResults, 'eph', eph, ...
                        'outDir', outDir);
                catch ME
                    warning('runFromJsonConfig:NMEA', '%s', ME.message);
                end
            end
        end

        %% Plot (all entry points use the same figure subdirectories)
        if doPlot && ~isempty(navSolutions)
            report.stage = 'plot';
            writeReportJson(fullfile(outDir, 'report.json'), report);
            fprintf('--- Plot / Baidu ---\n');
            try
                plotNavPost(navSolutions, settings, ...
                    'saveDir', navFigDir, ...
                    'doLegacy', false, ...
                    'openBaiduMap', doBaidu, ...
                    'openBaiduBrowser', p.Results.openBaiduBrowser);
            catch ME
                warning('runFromJsonConfig:Plot', '%s', ME.message);
            end
        end

        if ~isempty(navSolutions) && isfield(navSolutions, 'latitude')
            ok = isfinite(navSolutions.latitude) & isfinite(navSolutions.longitude);
            report.navSummary.nFixes = nnz(ok);
            if any(ok)
                report.navSummary.meanLat = mean(navSolutions.latitude(ok));
                report.navSummary.meanLon = mean(navSolutions.longitude(ok));
                if isfield(navSolutions, 'height')
                    hh = navSolutions.height(ok);
                    report.navSummary.meanH = mean(hh(isfinite(hh)));
                end
            end
        end

        % Store tracking objects as plain structures for portable replay.
        % The small UI MAT and full scientific archive serve different uses.
        report.stage = 'saving';
        writeReportJson(fullfile(outDir, 'report.json'), report);
        results = struct( ...
            'settings', settings, ...
            'acqResults', acqResults, ...
            'channel', channel, ...
            'trackResults', trackResults, ...
            'navSolutions', navSolutions, ...
            'eph', eph);
        diskPayload.results = results;
        diskPayload.results.trackResults = trackResultsToStruct(trackResults);
        diskPayload.settings = settings;
        writeUiResultsMat(fullfile(outDir, 'ui_results.mat'), results);
        diskPayload = rmfield(diskPayload, 'settings');
        save(fullfile(outDir, sprintf('run_B2a_%s.mat', tag)), ...
            '-struct', 'diskPayload', '-v7.3');
        clear diskPayload

        report.ok = true;
        report.stage = 'done';
        fprintf('========== UI pipeline DONE fixes=%d ==========\n', ...
            report.navSummary.nFixes);
    catch ME
        report.ok = false;
        report.errorIdentifier = ME.identifier;
        report.error = ME.message;
        if strcmp(report.stage, 'start'), report.stage = 'failed'; end
        fprintf(2, 'FAILED at %s: %s\n', report.stage, ME.message);
        try
            fprintf(2, '%s\n', getReport(ME, 'basic'));
        catch
        end
        % Keep the same product shape for partial runs.  The wrapper is
        % intentionally lightweight and safe after a long tracking failure.
        try
            partialResults = struct('settings', settings, ...
                'acqResults', acqResults, 'channel', channel, ...
                'trackResults', [], 'navSolutions', navSolutions, 'eph', eph);
            writeUiResultsMat(fullfile(outDir, 'ui_results.mat'), partialResults);
        catch wrapperError
            warning('runFromJsonConfig:PartialUiResults', ...
                'Could not write partial ui_results.mat: %s', wrapperError.message);
        end
    end

    writeReportJson(fullfile(outDir, 'report.json'), report);
    fprintf('report.json -> %s\n', fullfile(outDir, 'report.json'));
end

function localClose(fid)
% Cleanup must not replace the original pipeline exception.
    if ~isempty(fid) && fid > 0
        try
            fclose(fid);
        catch
        end
    end
end

function prn = localChannelPrn(channel)
% Accept both legacy channel structures and channel objects for plot export.
    prn = 0;
    if isstruct(channel) && isfield(channel, 'PRN') && ...
            isnumeric(channel.PRN) && isscalar(channel.PRN)
        prn = double(channel.PRN);
    elseif isobject(channel) && isprop(channel, 'PRN')
        value = channel.PRN;
        if isnumeric(value) && isscalar(value), prn = double(value); end
    end
end

function localExportAcquisitionFigure(acqResults, settings, outputDir)
% Own only newly created figures; leave the user's existing figures alone.
    figuresBefore = findall(groot, 'Type', 'figure');
    try
        plotAcquisition(acqResults, settings.acqSatelliteList);
        figuresAfter = findall(groot, 'Type', 'figure');
        newFigures = figuresAfter(~ismember(figuresAfter, figuresBefore));
        if ~isempty(newFigures)
            fig = newFigures(1);
            set(findall(fig, '-property', 'FontSize'), 'FontSize', 14);
            saveas(fig, fullfile(outputDir, 'acquisition_metrics.png'));
            close(fig);
        end
    catch ME
        figuresAfter = findall(groot, 'Type', 'figure');
        for idx = 1:numel(figuresAfter)
            fig = figuresAfter(idx);
            if isempty(figuresBefore) || ~any(fig == figuresBefore), close(fig); end
        end
        warning('runFromJsonConfig:PlotAcquisition', '%s', ME.message);
    end
end

function tf = localFlag(raw, name, default)
% UI-compatible coercion shared by both transports (including legacy flags).
    tf = default;
    if ~isfield(raw, name), return; end
    v = raw.(name);
    if islogical(v) && isscalar(v), tf = v; return; end
    if isnumeric(v) && isscalar(v), tf = v ~= 0; return; end
    if ischar(v) || isstring(v)
        tf = any(strcmpi(strtrim(char(v)), {'1','true','yes','on'}));
    end
end

function tf = localLogicalScalar(value)
% Execution options accept scalar logicals or finite numeric truth values.
    tf = (islogical(value) || isnumeric(value)) && isscalar(value) && isfinite(value);
end

function tf = localNestedFlag(raw, parent, name, default)
% Read a legacy nested switch using the same coercion as top-level do* flags.
    tf = default;
    if isfield(raw, parent) && isstruct(raw.(parent)) && isscalar(raw.(parent))
        tf = localFlag(raw.(parent), name, default);
    end
end

function s = localStr(raw, name, default)
% Empty optional strings use their fallback instead of suppressing filenames.
    s = default;
    if isfield(raw, name) && ~isempty(raw.(name))
        s = char(string(raw.(name)));
    end
end

function localCloseNewFigures(figuresBefore, enabled)
% onCleanup also runs after a stage failure; never close pre-existing figures.
    if ~enabled, return; end
    figuresAfter = findall(groot, 'Type', 'figure');
    for i = 1:numel(figuresAfter)
        h = figuresAfter(i);
        try
            if isempty(figuresBefore) || ~any(h == figuresBefore)
                close(h);
            end
        catch
        end
    end
end

function writeReportJson(path, report)
    % Best-effort progress reporting; a small fallback handles nested empties
    % on older MATLAB releases without hiding the underlying stage failure.
    try
        txt = jsonencode(report);
    catch
        txt = sprintf(['{"ok":%s,"stage":"%s","outDir":"%s","error":"%s",' ...
            '"nAcquired":%d,"navSummary":{"nFixes":%d,"meanLat":%g,"meanLon":%g,"meanH":%g}}'], ...
            mat2str(logical(report.ok)), ...
            localEsc(report.stage), localEsc(report.outDir), localEsc(report.error), ...
            report.nAcquired, report.navSummary.nFixes, ...
            report.navSummary.meanLat, report.navSummary.meanLon, report.navSummary.meanH);
    end
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, txt, 'char');
end

function localWriteJson(path, value)
% Config snapshots require a writable UTF-8 file; callers decide error policy.
    try
        text = jsonencode(value, 'PrettyPrint', true);
    catch
        text = jsonencode(value);
    end
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0
        error('runFromJsonConfig:WriteJson', 'Cannot write JSON file: %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, text, 'char');
end

function t = localEsc(s)
% Sanitize text used only by the legacy minimal report-serialization fallback.
    t = char(string(s));
    t = strrep(t, '\', '/');
    t = strrep(t, '"', '''');
    t = strrep(t, newline, ' ');
end
