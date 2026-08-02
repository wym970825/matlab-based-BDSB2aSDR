function [report, replayData] = replayTrackingChannels(rootDir, varargin)
%REPLAYTRACKINGCHANNELS Load final tracking MAT files and replay diagnostics.
%
%   report = replayTrackingChannels(rootDir)
%   [report, replayData] = replayTrackingChannels(rootDir, Name, Value, ...)
%
% ROOTDIR can be either one receiver-run directory containing TEMP or a
% batch root containing numbered run directories. Each run is treated as
% one merged channel set. By default, figures are written below:
%
%   <runDir>/figures/trkResult
%
% Supported MAT variables include finalTRes, obj, trackResults, and any
% scalar object/struct exposing a PRN property/field. This lets old and new
% TrackResults2 files use the same replay path without the original IF data.
%
% Name-value options:
%   RunNames          Exact run directory names to include (default: all)
%   RunPattern        Regexp for discovered run names (default: numbered)
%   Recursive         Discover TEMP folders recursively (default: false)
%   TempSubdir        Tracking MAT subdirectory (default: 'temp')
%   ResultPattern     MAT file glob (default: 'Trk_Prn_*_final.mat')
%   PrnExpression     Filename regexp with PRN in token 1
%   OutputSubdir      Figure path below each run
%   PRNs              PRN subset; empty means all
%   Visible           Show replay figures (default: false)
%   Overwrite         Replace existing exports (default: true)
%   Resolution        PNG resolution in DPI (default: 140)
%   SaveFigure        Also write editable .fig files (default: false)
%   MaxPlotPoints     Display decimation cap per trace (default: 20000)
%   ContinueOnError   Continue with other channels/runs (default: true)
%   KeepLoadedResults Return merged channel arrays in replayData
%   WriteReport       Write replay_report.json per run (default: true)

    setupPaths();
    rootDir = localTextScalar(rootDir, 'rootDir');
    opts = localParseOptions(varargin{:});

    if ~isfolder(rootDir)
        error('replayTrackingChannels:MissingRoot', ...
            'Tracking replay root does not exist: %s', rootDir);
    end

    runDirs = localDiscoverRuns(rootDir, opts);
    if isempty(runDirs)
        error('replayTrackingChannels:NoRuns', ...
            'No run containing %s/%s was found below %s.', ...
            opts.TempSubdir, opts.ResultPattern, rootDir);
    end

    started = tic;
    runReports = repmat(localEmptyRunReport(), 0, 1);
    replayData = repmat(struct( ...
        'runDir', '', 'prns', [], 'trackResults', []), 0, 1);

    for runIdx = 1:numel(runDirs)
        runDir = runDirs{runIdx};
        fprintf('\n[%d/%d] Replaying tracking channels: %s\n', ...
            runIdx, numel(runDirs), runDir);
        try
            [runReport, runData] = localReplayRun(runDir, opts);
        catch ME
            runReport = localEmptyRunReport();
            runReport.runDir = runDir;
            runReport.runName = localBaseName(runDir);
            runReport.status = 'failed';
            runReport.errors = localErrorRecord('run', runDir, ME);
            runData = struct('runDir', runDir, 'prns', [], ...
                'trackResults', []);
            fprintf(2, 'Replay failed for %s: %s\n', runDir, ME.message);
            if ~opts.ContinueOnError
                rethrow(ME);
            end
        end
        runReports(end + 1, 1) = runReport; %#ok<AGROW>
        if opts.KeepLoadedResults && ~isempty(runData.trackResults)
            replayData(end + 1, 1) = runData; %#ok<AGROW>
        end
    end

    statuses = {runReports.status};
    report = struct();
    report.generatedAt = char(datetime('now', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
    report.rootDir = rootDir;
    report.nRuns = numel(runReports);
    report.nSucceeded = nnz(strcmp(statuses, 'succeeded'));
    report.nPartial = nnz(strcmp(statuses, 'partial'));
    report.nFailed = nnz(strcmp(statuses, 'failed'));
    report.nChannels = sum([runReports.nChannels]);
    report.nFigures = sum([runReports.nFigures]);
    report.nErrors = sum(arrayfun(@(x) numel(x.errors), runReports));
    report.elapsedSeconds = toc(started);
    report.ok = report.nFailed == 0 && report.nPartial == 0;
    report.runs = runReports;

    fprintf(['\nReplay summary: runs=%d, channels=%d, figures=%d, ' ...
        'errors=%d, elapsed=%.1f s\n'], report.nRuns, report.nChannels, ...
        report.nFigures, report.nErrors, report.elapsedSeconds);
end

function opts = localParseOptions(varargin)
    p = inputParser;
    p.FunctionName = 'replayTrackingChannels';
    addParameter(p, 'RunNames', strings(0, 1), ...
        @(x) ischar(x) || isstring(x) || iscellstr(x));
    addParameter(p, 'RunPattern', '^\d+_.+', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'Recursive', false, @localLogicalScalar);
    addParameter(p, 'TempSubdir', 'temp', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'ResultPattern', 'Trk_Prn_*_final.mat', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'PrnExpression', '^Trk_Prn_(\d+)_final\.mat$', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'OutputSubdir', fullfile('figures', 'trkResult'), ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'PRNs', [], ...
        @(x) isnumeric(x) && isvector(x) && all(isfinite(x)));
    addParameter(p, 'Visible', false, @localLogicalScalar);
    addParameter(p, 'Overwrite', true, @localLogicalScalar);
    addParameter(p, 'Resolution', 140, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(p, 'SaveFigure', false, @localLogicalScalar);
    addParameter(p, 'MaxPlotPoints', 20000, ...
        @(x) isnumeric(x) && isscalar(x) && x > 0);
    addParameter(p, 'ContinueOnError', true, @localLogicalScalar);
    addParameter(p, 'KeepLoadedResults', false, @localLogicalScalar);
    addParameter(p, 'WriteReport', true, @localLogicalScalar);
    parse(p, varargin{:});

    opts = p.Results;
    opts.RunNames = string(opts.RunNames(:));
    opts.RunPattern = char(opts.RunPattern);
    opts.TempSubdir = char(opts.TempSubdir);
    opts.ResultPattern = char(opts.ResultPattern);
    opts.PrnExpression = char(opts.PrnExpression);
    opts.OutputSubdir = char(opts.OutputSubdir);
    opts.PRNs = unique(double(opts.PRNs(:).'), 'sorted');
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value) ...
        && isfinite(double(value));
end

function runDirs = localDiscoverRuns(rootDir, opts)
    runDirs = {};
    directTemp = fullfile(rootDir, opts.TempSubdir);
    if localHasTrackingFiles(directTemp, opts)
        runDirs = {rootDir};
        return;
    end

    candidates = {};
    if opts.Recursive
        tempEntries = dir(fullfile(rootDir, '**', opts.TempSubdir));
        tempEntries = tempEntries([tempEntries.isdir]);
        for idx = 1:numel(tempEntries)
            candidates{end + 1} = tempEntries(idx).folder; %#ok<AGROW>
        end
    else
        entries = dir(rootDir);
        entries = entries([entries.isdir]);
        entries = entries(~ismember({entries.name}, {'.', '..'}));
        for idx = 1:numel(entries)
            candidates{end + 1} = fullfile(entries(idx).folder, ...
                entries(idx).name); %#ok<AGROW>
        end
    end

    for idx = 1:numel(candidates)
        candidate = candidates{idx};
        runName = localBaseName(candidate);
        if ~isempty(opts.RunPattern) ...
                && isempty(regexp(runName, opts.RunPattern, 'once'))
            continue;
        end
        if ~isempty(opts.RunNames) && ~any(strcmpi(runName, opts.RunNames))
            continue;
        end
        if localHasTrackingFiles(fullfile(candidate, opts.TempSubdir), opts)
            runDirs{end + 1} = candidate; %#ok<AGROW>
        end
    end

    if isempty(runDirs)
        return;
    end
    runDirs = unique(runDirs, 'stable');
    names = cellfun(@localBaseName, runDirs, 'UniformOutput', false);
    [~, order] = sort(lower(string(names)));
    runDirs = runDirs(order);
end

function tf = localHasTrackingFiles(tempDir, opts)
    tf = false;
    if ~isfolder(tempDir)
        return;
    end
    entries = dir(fullfile(tempDir, opts.ResultPattern));
    for idx = 1:numel(entries)
        if ~entries(idx).isdir && ~isempty(regexp( ...
                entries(idx).name, opts.PrnExpression, 'once'))
            tf = true;
            return;
        end
    end
end

function [runReport, runData] = localReplayRun(runDir, opts)
    runStarted = tic;
    runReport = localEmptyRunReport();
    runReport.runDir = runDir;
    runReport.runName = localBaseName(runDir);
    runData = struct('runDir', runDir, 'prns', [], 'trackResults', []);

    tempDir = fullfile(runDir, opts.TempSubdir);
    outputDir = fullfile(runDir, opts.OutputSubdir);
    if ~isfolder(outputDir)
        [made, message] = mkdir(outputDir);
        if ~made
            error('replayTrackingChannels:CreateOutput', ...
                'Cannot create %s: %s', outputDir, message);
        end
    end
    runReport.tempDir = tempDir;
    runReport.outputDir = outputDir;

    [matFiles, filePrns] = localTrackingFiles(tempDir, opts);
    if isempty(matFiles)
        error('replayTrackingChannels:NoChannels', ...
            'No matching final tracking MAT files in %s.', tempDir);
    end

    channels = cell(1, numel(matFiles));
    loadedPrns = nan(1, numel(matFiles));
    loadedFiles = cell(1, numel(matFiles));
    keep = false(1, numel(matFiles));
    for idx = 1:numel(matFiles)
        sourcePath = fullfile(matFiles(idx).folder, matFiles(idx).name);
        try
            channel = localLoadChannel(sourcePath, filePrns(idx));
            actualPrn = localScalarValue(channel, 'PRN', filePrns(idx));
            channels{idx} = channel;
            loadedPrns(idx) = actualPrn;
            loadedFiles{idx} = sourcePath;
            keep(idx) = true;
            fprintf('  Loaded PRN %02d: %s\n', actualPrn, matFiles(idx).name);
        catch ME
            runReport.errors(end + 1) = localErrorRecord( ...
                'load', sourcePath, ME);
            fprintf(2, '  Load failed: %s (%s)\n', sourcePath, ME.message);
            if ~opts.ContinueOnError
                rethrow(ME);
            end
        end
    end
    channels = channels(keep);
    loadedPrns = loadedPrns(keep);
    loadedFiles = loadedFiles(keep);
    if isempty(channels)
        error('replayTrackingChannels:NoLoadableChannels', ...
            'No tracking channel could be loaded from %s.', tempDir);
    end

    [loadedPrns, order] = sort(loadedPrns);
    channels = channels(order);
    loadedFiles = loadedFiles(order);
    settings = localLoadPlotSettings(runDir, channels);

    runReport.prns = loadedPrns;
    runReport.nChannels = numel(channels);
    runReport.sourceFiles = loadedFiles;
    runReport.settingsSource = settings.source;
    figureFiles = {};

    for idx = 1:numel(channels)
        prn = loadedPrns(idx);
        pngPath = fullfile(outputDir, ...
            sprintf('PRN_%02d_tracking_replay.png', prn));
        figPath = fullfile(outputDir, ...
            sprintf('PRN_%02d_tracking_replay.fig', prn));
        if ~opts.Overwrite && isfile(pngPath) ...
                && (~opts.SaveFigure || isfile(figPath))
            figureFiles{end + 1} = pngPath; %#ok<AGROW>
            if opts.SaveFigure
                figureFiles{end + 1} = figPath; %#ok<AGROW>
            end
            fprintf('  Existing PRN %02d figure kept.\n', prn);
            continue;
        end

        fig = gobjects(0);
        try
            fig = localChannelFigure(channels{idx}, prn, ...
                runReport.runName, settings.value, opts);
            exportgraphics(fig, pngPath, 'Resolution', opts.Resolution);
            figureFiles{end + 1} = pngPath; %#ok<AGROW>
            if opts.SaveFigure
                savefig(fig, figPath);
                figureFiles{end + 1} = figPath; %#ok<AGROW>
            end
            close(fig);
            fprintf('  Plotted PRN %02d -> %s\n', prn, pngPath);
        catch ME
            if ~isempty(fig) && all(isgraphics(fig))
                close(fig);
            end
            runReport.errors(end + 1) = localErrorRecord( ...
                'channelPlot', loadedFiles{idx}, ME);
            fprintf(2, '  Plot failed for PRN %02d: %s\n', prn, ME.message);
            if ~opts.ContinueOnError
                rethrow(ME);
            end
        end
    end

    overviewPath = fullfile(outputDir, 'all_channels_overview.png');
    overviewFigPath = fullfile(outputDir, 'all_channels_overview.fig');
    if opts.Overwrite || ~isfile(overviewPath) ...
            || (opts.SaveFigure && ~isfile(overviewFigPath))
        fig = gobjects(0);
        try
            fig = localOverviewFigure(channels, loadedPrns, ...
                runReport.runName, settings.value, opts);
            exportgraphics(fig, overviewPath, 'Resolution', opts.Resolution);
            figureFiles{end + 1} = overviewPath;
            if opts.SaveFigure
                savefig(fig, overviewFigPath);
                figureFiles{end + 1} = overviewFigPath;
            end
            close(fig);
            fprintf('  Plotted all-channel overview -> %s\n', overviewPath);
        catch ME
            if ~isempty(fig) && all(isgraphics(fig))
                close(fig);
            end
            runReport.errors(end + 1) = localErrorRecord( ...
                'overviewPlot', runDir, ME);
            fprintf(2, '  Overview plot failed: %s\n', ME.message);
            if ~opts.ContinueOnError
                rethrow(ME);
            end
        end
    else
        figureFiles{end + 1} = overviewPath;
        if opts.SaveFigure
            figureFiles{end + 1} = overviewFigPath;
        end
    end

    runReport.figureFiles = figureFiles;
    runReport.nFigures = numel(figureFiles);
    runReport.elapsedSeconds = toc(runStarted);
    if isempty(runReport.errors)
        runReport.status = 'succeeded';
    else
        runReport.status = 'partial';
    end

    if opts.KeepLoadedResults
        runData.prns = loadedPrns;
        runData.trackResults = localMergeChannels(channels);
    end

    if opts.WriteReport
        reportPath = fullfile(outputDir, 'replay_report.json');
        runReport.reportPath = reportPath;
        localWriteJson(reportPath, runReport);
    end
end

function [files, prns] = localTrackingFiles(tempDir, opts)
    files = dir(fullfile(tempDir, opts.ResultPattern));
    files = files(~[files.isdir]);
    prns = nan(1, numel(files));
    keep = false(1, numel(files));
    for idx = 1:numel(files)
        token = regexp(files(idx).name, opts.PrnExpression, 'tokens', 'once');
        if isempty(token)
            continue;
        end
        prn = str2double(token{1});
        if ~isfinite(prn) || (~isempty(opts.PRNs) && ~ismember(prn, opts.PRNs))
            continue;
        end
        prns(idx) = prn;
        keep(idx) = true;
    end
    files = files(keep);
    prns = prns(keep);
    [prns, order] = sort(prns);
    files = files(order);
end

function channel = localLoadChannel(path, expectedPrn)
    loaded = load(path);
    preferred = {'finalTRes', 'obj', 'trackResults'};
    candidates = [preferred, setdiff(fieldnames(loaded).', preferred, 'stable')];
    channel = [];
    for idx = 1:numel(candidates)
        name = candidates{idx};
        if ~isfield(loaded, name)
            continue;
        end
        value = loaded.(name);
        if isempty(value)
            continue;
        end
        for valueIdx = 1:numel(value)
            item = value(valueIdx);
            if ~localHasMember(item, 'PRN')
                continue;
            end
            itemPrn = localScalarValue(item, 'PRN', nan);
            if isempty(channel) || isequal(itemPrn, expectedPrn)
                channel = item;
            end
            if isequal(itemPrn, expectedPrn)
                return;
            end
        end
    end
    if isempty(channel)
        error('replayTrackingChannels:BadMat', ...
            'No tracking result with a PRN field/property in %s.', path);
    end
end

function settings = localLoadPlotSettings(runDir, channels)
    settings = struct('value', struct(), 'source', 'derived from tracking data');
    uiMat = fullfile(runDir, 'ui_results.mat');
    if isfile(uiMat)
        vars = whos('-file', uiMat);
        if any(strcmp({vars.name}, 'settings'))
            loaded = load(uiMat, 'settings');
            if isstruct(loaded.settings) && isscalar(loaded.settings)
                settings.value = loaded.settings;
                settings.source = uiMat;
            end
        end
    end
    if isempty(fieldnames(settings.value))
        jsonPath = fullfile(runDir, 'ui_config.json');
        if isfile(jsonPath)
            try
                value = jsondecode(fileread(jsonPath));
                if isstruct(value) && isscalar(value)
                    settings.value = value;
                    settings.source = jsonPath;
                end
            catch
            end
        end
    end

    settings.value.numberOfChannels = numel(channels);
    lengths = cellfun(@(x) localChannelLength(x), channels);
    lengths = lengths(isfinite(lengths) & lengths > 0);
    if ~isfield(settings.value, 'msToProcess') || isempty(settings.value.msToProcess)
        if isempty(lengths)
            settings.value.msToProcess = 0;
        else
            settings.value.msToProcess = max(lengths);
        end
    end
    if ~isfield(settings.value, 'intTime') || isempty(settings.value.intTime)
        settings.value.intTime = 1e-3;
    end
    if ~isfield(settings.value, 'CNoInterval') || isempty(settings.value.CNoInterval)
        cnoInterval = localScalarValue(channels{1}, 'CNoInterval', 200);
        settings.value.CNoInterval = cnoInterval;
    end
end

function fig = localChannelFigure(channel, prn, runName, settings, opts)
    fig = figure('Visible', localOnOff(opts.Visible), 'Color', 'w', ...
        'Position', [60 40 1600 980], ...
        'Name', sprintf('%s PRN %02d tracking replay', runName, prn));
    layout = tiledlayout(fig, 3, 3, 'TileSpacing', 'compact', ...
        'Padding', 'compact');
    dt = localTimeStep(settings);

    ax = nexttile(layout);
    localPlotIq(ax, channel, opts.MaxPlotPoints);
    title(ax, 'Prompt IQ'); xlabel(ax, 'I'); ylabel(ax, 'Q');

    ax = nexttile(layout);
    dataPower = localComplexPower(channel, 'I_P', 'Q_P');
    pilotPower = localComplexPower(channel, 'Pilot_I_P', 'Pilot_Q_P');
    localPlotTrace(ax, dataPower, dt, opts.MaxPlotPoints, 'Data');
    localPlotTrace(ax, pilotPower, dt, opts.MaxPlotPoints, 'Pilot');
    localFinishAxes(ax, 'Prompt power', 'Power', true);

    ax = nexttile(layout);
    cnoStep = localCNoStep(channel, settings, dt);
    localPlotTrace(ax, localVector(channel, 'DataCNo'), cnoStep, ...
        opts.MaxPlotPoints, 'Data');
    localPlotTrace(ax, localVector(channel, 'PilotCNo'), cnoStep, ...
        opts.MaxPlotPoints, 'Pilot');
    localPlotTrace(ax, localVector(channel, 'B2a_CNo'), cnoStep, ...
        opts.MaxPlotPoints, 'B2a');
    localFinishAxes(ax, 'C/N0', 'dB-Hz', true);

    ax = nexttile(layout);
    localPlotTrace(ax, localVector(channel, 'carrFreq'), dt, ...
        opts.MaxPlotPoints, 'Carrier');
    localFinishAxes(ax, 'Carrier frequency', 'Hz', false);

    ax = nexttile(layout);
    localPlotTrace(ax, localVector(channel, 'codeFreq'), dt, ...
        opts.MaxPlotPoints, 'Code');
    localFinishAxes(ax, 'Code frequency', 'Hz', false);

    ax = nexttile(layout);
    localPlotTrace(ax, localVector(channel, 'pllDiscr'), dt, ...
        opts.MaxPlotPoints, 'Raw');
    localPlotTrace(ax, localVector(channel, 'pllDiscrFilt'), dt, ...
        opts.MaxPlotPoints, 'Filtered');
    localFinishAxes(ax, 'PLL discriminator', 'Error', true);

    ax = nexttile(layout);
    localPlotTrace(ax, localVector(channel, 'dllDiscr'), dt, ...
        opts.MaxPlotPoints, 'Raw');
    localPlotTrace(ax, localVector(channel, 'dllDiscrFilt'), dt, ...
        opts.MaxPlotPoints, 'Filtered');
    localFinishAxes(ax, 'DLL discriminator', 'Error', true);

    ax = nexttile(layout);
    localPlotTrace(ax, localVector(channel, 'fllDiscrHz'), dt, ...
        opts.MaxPlotPoints, 'FLL raw');
    localPlotTrace(ax, localVector(channel, 'fllDiscrFiltHz'), dt, ...
        opts.MaxPlotPoints, 'FLL filtered');
    localPlotTrace(ax, localVector(channel, 'fllCorrHz'), dt, ...
        opts.MaxPlotPoints, 'FLL correction');
    localPlotTrace(ax, localVector(channel, 'kf_corrHz'), dt, ...
        opts.MaxPlotPoints, 'KF correction');
    localFinishAxes(ax, 'Frequency corrections', 'Hz', true);

    ax = nexttile(layout);
    state = localVector(channel, 'trk_state');
    if isempty(state)
        state = double(localVector(channel, 'cur_state'));
    end
    localPlotStairs(ax, state, dt, opts.MaxPlotPoints, 'State');
    aided = double(localVector(channel, 'fllAided'));
    localPlotStairs(ax, aided, dt, opts.MaxPlotPoints, 'FLL aided');
    localFinishAxes(ax, 'Tracking state', 'State / flag', true);

    status = localTextValue(channel, 'status', '?');
    sgtitle(layout, sprintf('%s | PRN %02d | status %s | N=%d', ...
        runName, prn, status, localChannelLength(channel)), ...
        'Interpreter', 'none');
end

function fig = localOverviewFigure(channels, prns, runName, settings, opts)
    fig = figure('Visible', localOnOff(opts.Visible), 'Color', 'w', ...
        'Position', [80 60 1500 900], ...
        'Name', sprintf('%s all-channel tracking overview', runName));
    layout = tiledlayout(fig, 2, 2, 'TileSpacing', 'compact', ...
        'Padding', 'compact');
    dt = localTimeStep(settings);

    ax = nexttile(layout);
    for idx = 1:numel(channels)
        cno = localBestCNo(channels{idx});
        localPlotTrace(ax, cno, localCNoStep(channels{idx}, settings, dt), ...
            opts.MaxPlotPoints, sprintf('PRN %02d', prns(idx)));
    end
    localFinishAxes(ax, 'C/N0 by channel', 'dB-Hz', true);

    ax = nexttile(layout);
    for idx = 1:numel(channels)
        value = localCentered(localVector(channels{idx}, 'carrFreq'));
        localPlotTrace(ax, value, dt, opts.MaxPlotPoints, ...
            sprintf('PRN %02d', prns(idx)));
    end
    localFinishAxes(ax, 'Carrier deviation from median', 'Hz', true);

    ax = nexttile(layout);
    for idx = 1:numel(channels)
        value = localCentered(localVector(channels{idx}, 'codeFreq'));
        localPlotTrace(ax, value, dt, opts.MaxPlotPoints, ...
            sprintf('PRN %02d', prns(idx)));
    end
    localFinishAxes(ax, 'Code deviation from median', 'Hz', true);

    ax = nexttile(layout);
    hold(ax, 'on');
    stride = 10;
    tickLocations = zeros(1, numel(channels));
    for idx = 1:numel(channels)
        state = localVector(channels{idx}, 'trk_state');
        if isempty(state)
            state = double(localVector(channels{idx}, 'cur_state'));
        end
        offset = (idx - 1) * stride;
        tickLocations(idx) = offset + 4.5;
        localPlotStairs(ax, double(state) + offset, dt, ...
            opts.MaxPlotPoints, sprintf('PRN %02d', prns(idx)));
    end
    grid(ax, 'on'); xlabel(ax, 'Time (s)'); ylabel(ax, 'PRN / state');
    title(ax, 'Tracking-state timelines (offset per PRN)');
    yticks(ax, tickLocations);
    yticklabels(ax, compose('PRN %02d', prns));

    sgtitle(layout, sprintf('%s | %d replayed channels', ...
        runName, numel(channels)), 'Interpreter', 'none');
end

function localPlotIq(ax, channel, maxPoints)
    hold(ax, 'on'); grid(ax, 'on'); axis(ax, 'equal');
    localScatterPair(ax, localVector(channel, 'I_P'), ...
        localVector(channel, 'Q_P'), maxPoints, 'Data');
    localScatterPair(ax, localVector(channel, 'Pilot_I_P'), ...
        localVector(channel, 'Pilot_Q_P'), maxPoints, 'Pilot');
    localLegend(ax);
    localMarkEmpty(ax);
end

function localScatterPair(ax, x, y, maxPoints, label)
    n = min(numel(x), numel(y));
    if n == 0
        return;
    end
    indices = localIndices(n, maxPoints);
    scatter(ax, double(x(indices)), double(y(indices)), 4, 'filled', ...
        'MarkerFaceAlpha', 0.25, 'DisplayName', label);
end

function localPlotTrace(ax, value, step, maxPoints, label)
    if isempty(value)
        return;
    end
    value = double(value(:).');
    indices = localIndices(numel(value), maxPoints);
    time = (indices - 1) * step;
    hold(ax, 'on');
    plot(ax, time, value(indices), 'DisplayName', label, 'LineWidth', 0.8);
end

function localPlotStairs(ax, value, step, maxPoints, label)
    if isempty(value)
        return;
    end
    value = double(value(:).');
    indices = localIndices(numel(value), maxPoints);
    time = (indices - 1) * step;
    hold(ax, 'on');
    stairs(ax, time, value(indices), 'DisplayName', label, 'LineWidth', 0.8);
end

function indices = localIndices(n, maxPoints)
    if isinf(maxPoints) || n <= maxPoints
        indices = 1:n;
    else
        indices = unique(round(linspace(1, n, max(2, floor(maxPoints)))));
    end
end

function localFinishAxes(ax, plotTitle, yLabelText, showLegend)
    grid(ax, 'on'); xlabel(ax, 'Time (s)'); ylabel(ax, yLabelText);
    title(ax, plotTitle);
    if showLegend
        localLegend(ax);
    end
    localMarkEmpty(ax);
end

function localLegend(ax)
    children = findobj(ax, '-property', 'DisplayName');
    names = get(children, 'DisplayName');
    if ischar(names)
        names = {names};
    end
    if ~isempty(names) && any(~cellfun('isempty', names))
        legend(ax, 'show', 'Location', 'best');
    end
end

function localMarkEmpty(ax)
    if isempty(findobj(ax, 'Type', 'line')) ...
            && isempty(findobj(ax, 'Type', 'scatter'))
        text(ax, 0.5, 0.5, 'No saved data', 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
    end
end

function value = localBestCNo(channel)
    value = localVector(channel, 'B2a_CNo');
    if isempty(value) || ~any(isfinite(value))
        value = localVector(channel, 'PilotCNo');
    end
    if isempty(value) || ~any(isfinite(value))
        value = localVector(channel, 'DataCNo');
    end
end

function value = localCentered(value)
    if isempty(value)
        return;
    end
    finiteValues = value(isfinite(value));
    if ~isempty(finiteValues)
        value = value - median(finiteValues);
    end
end

function value = localComplexPower(channel, iName, qName)
    iValue = localVector(channel, iName);
    qValue = localVector(channel, qName);
    n = min(numel(iValue), numel(qValue));
    if n == 0
        value = [];
    else
        value = double(iValue(1:n)).^2 + double(qValue(1:n)).^2;
    end
end

function value = localVector(container, name)
    value = [];
    if isstruct(container) && isfield(container, name)
        value = container.(name);
    elseif isobject(container) && isprop(container, name)
        value = container.(name);
    end
    if ~(isnumeric(value) || islogical(value)) || ~isvector(value)
        value = [];
    end
end

function tf = localHasMember(container, name)
    tf = (isstruct(container) && isfield(container, name)) ...
        || (isobject(container) && isprop(container, name));
end

function value = localScalarValue(container, name, fallback)
    value = fallback;
    if localHasMember(container, name)
        candidate = container.(name);
        if isnumeric(candidate) && isscalar(candidate) && isfinite(candidate)
            value = double(candidate);
        end
    end
end

function value = localTextValue(container, name, fallback)
    value = fallback;
    if localHasMember(container, name)
        candidate = container.(name);
        if ischar(candidate) || (isstring(candidate) && isscalar(candidate))
            value = char(candidate);
        end
    end
end

function n = localChannelLength(channel)
    n = localScalarValue(channel, 'Nsize', nan);
    if isfinite(n) && n > 0
        n = floor(n);
        return;
    end
    names = {'I_P', 'Pilot_I_P', 'carrFreq', 'pllDiscrFilt'};
    lengths = zeros(size(names));
    for idx = 1:numel(names)
        lengths(idx) = numel(localVector(channel, names{idx}));
    end
    n = max(lengths);
end

function step = localTimeStep(settings)
    step = 1e-3;
    if isstruct(settings) && isfield(settings, 'intTime') ...
            && isnumeric(settings.intTime) && isscalar(settings.intTime) ...
            && isfinite(settings.intTime) && settings.intTime > 0
        step = double(settings.intTime);
    end
end

function step = localCNoStep(channel, settings, timeStep)
    interval = localScalarValue(channel, 'CNoInterval', nan);
    if ~isfinite(interval) && isstruct(settings) ...
            && isfield(settings, 'CNoInterval')
        interval = double(settings.CNoInterval);
    end
    if ~isfinite(interval) || interval <= 0
        interval = 200;
    end
    step = interval * timeStep;
end

function merged = localMergeChannels(channels)
    if isempty(channels)
        merged = [];
        return;
    end
    if all(cellfun(@isstruct, channels))
        try
            merged = [channels{:}];
            return;
        catch
        end
    elseif all(cellfun(@isobject, channels)) ...
            && isscalar(unique(cellfun(@class, channels, ...
                'UniformOutput', false)))
        try
            merged = channels{1};
            for idx = 2:numel(channels)
                merged(1, idx) = channels{idx};
            end
            return;
        catch
        end
    end
    merged = channels;
end

function value = localOnOff(tf)
    if logical(tf)
        value = 'on';
    else
        value = 'off';
    end
end

function report = localEmptyRunReport()
    report = struct( ...
        'runName', '', ...
        'runDir', '', ...
        'tempDir', '', ...
        'outputDir', '', ...
        'settingsSource', '', ...
        'status', 'pending', ...
        'prns', [], ...
        'nChannels', 0, ...
        'sourceFiles', {{}}, ...
        'figureFiles', {{}}, ...
        'nFigures', 0, ...
        'errors', struct('stage', {}, 'source', {}, ...
            'identifier', {}, 'message', {}), ...
        'elapsedSeconds', 0, ...
        'reportPath', '');
end

function record = localErrorRecord(stage, source, exception)
    record = struct('stage', stage, 'source', source, ...
        'identifier', exception.identifier, 'message', exception.message);
end

function localWriteJson(path, value)
    text = jsonencode(value, 'PrettyPrint', true);
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0
        error('replayTrackingChannels:WriteReport', ...
            'Cannot open replay report for writing: %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, text, 'char');
end

function name = localBaseName(path)
    [~, name] = fileparts(path);
end

function value = localTextScalar(value, argumentName)
    if ~(ischar(value) || (isstring(value) && isscalar(value)))
        error('replayTrackingChannels:TextScalar', ...
            '%s must be a character vector or string scalar.', argumentName);
    end
    value = char(value);
end
