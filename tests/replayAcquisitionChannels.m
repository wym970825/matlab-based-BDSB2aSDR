function [report, replayData] = replayAcquisitionChannels(rootDir, varargin)
%REPLAYACQUISITIONCHANNELS Replay saved acquisition results without IF data.
%
%   report = replayAcquisitionChannels(rootDir)
%   [report, replayData] = replayAcquisitionChannels(rootDir, Name, Value)
%
% ROOTDIR can be one receiver-run directory or a batch root containing run
% directories. Current UI output (results.acqResults in ui_results.mat), a
% standalone acqResults variable, and smoke/result wrapper structs are
% supported. Figures are written below each run by default:
%
%   <runDir>/figures/AcqResult
%
% The plot is produced by plotAcquisition and then restyled for readable
% debug output with larger fonts and an acquisition-threshold reference.
%
% Name-value options:
%   RunNames          Exact run directory names to include (default: all)
%   RunPattern        Regexp for discovered run names (default: numbered)
%   Recursive         Discover result files recursively (default: false)
%   ResultFiles       Preferred MAT filename patterns, in priority order
%   OutputSubdir      Figure path below each run
%   PRNs              PRN subset; empty means every searched satellite
%   Visible           Show replay figures (default: false)
%   Overwrite         Replace existing exports (default: true)
%   Resolution        PNG resolution in DPI (default: 150)
%   SaveFigure        Also write an editable .fig file (default: false)
%   FontSize          Axes, tick, and legend font size (default: 16)
%   TitleFontSize     Panel-title font size (default: 19)
%   ContinueOnError   Continue with other runs (default: true)
%   KeepLoadedResults Return acquisition structs in replayData
%   WriteReport       Write replay_report.json per run (default: true)

    setupPaths();
    rootDir = localTextScalar(rootDir, 'rootDir');
    opts = localParseOptions(varargin{:});
    if ~isfolder(rootDir)
        error('replayAcquisitionChannels:MissingRoot', ...
            'Acquisition replay root does not exist: %s', rootDir);
    end

    runSources = localDiscoverRuns(rootDir, opts);
    if isempty(runSources)
        error('replayAcquisitionChannels:NoRuns', ...
            'No saved acquisition result was found below %s.', rootDir);
    end

    started = tic;
    runReports = repmat(localEmptyRunReport(), 0, 1);
    replayData = repmat(struct('runDir', '', 'sourcePath', '', ...
        'satelliteList', [], 'acquiredPrns', [], 'acqResults', [], ...
        'settings', struct()), 0, 1);

    for runIdx = 1:numel(runSources)
        runDir = runSources(runIdx).runDir;
        sourcePath = runSources(runIdx).sourcePath;
        fprintf('\n[%d/%d] Replaying acquisition: %s\n', ...
            runIdx, numel(runSources), runDir);
        try
            [runReport, runData] = localReplayRun( ...
                runDir, sourcePath, opts);
        catch ME
            runReport = localEmptyRunReport();
            runReport.runName = localBaseName(runDir);
            runReport.runDir = runDir;
            runReport.sourcePath = sourcePath;
            runReport.status = 'failed';
            runReport.errors = localErrorRecord('run', sourcePath, ME);
            runData = localEmptyReplayData();
            fprintf(2, 'Acquisition replay failed for %s: %s\n', ...
                runDir, ME.message);
            if ~opts.ContinueOnError
                rethrow(ME);
            end
        end
        runReports(end + 1, 1) = runReport; %#ok<AGROW>
        if opts.KeepLoadedResults && ~isempty(runData.acqResults)
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
    report.nSearched = sum([runReports.nSearched]);
    report.nAcquired = sum([runReports.nAcquired]);
    report.nFigures = sum([runReports.nFigures]);
    report.nErrors = sum(arrayfun(@(x) numel(x.errors), runReports));
    report.elapsedSeconds = toc(started);
    report.ok = report.nFailed == 0 && report.nPartial == 0;
    report.runs = runReports;

    fprintf(['\nAcquisition replay summary: runs=%d, searched=%d, ' ...
        'acquired=%d, figures=%d, errors=%d, elapsed=%.1f s\n'], ...
        report.nRuns, report.nSearched, report.nAcquired, ...
        report.nFigures, report.nErrors, report.elapsedSeconds);
end

function opts = localParseOptions(varargin)
    p = inputParser;
    p.FunctionName = 'replayAcquisitionChannels';
    addParameter(p, 'RunNames', strings(0, 1), ...
        @(x) ischar(x) || isstring(x) || iscellstr(x));
    addParameter(p, 'RunPattern', '^\d+_.+', ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'Recursive', false, @localLogicalScalar);
    addParameter(p, 'ResultFiles', ...
        {'acq_results.mat', 'ui_results.mat', 'run_B2a_*.mat'}, ...
        @(x) ischar(x) || isstring(x) || iscellstr(x));
    addParameter(p, 'OutputSubdir', fullfile('figures', 'AcqResult'), ...
        @(x) ischar(x) || (isstring(x) && isscalar(x)));
    addParameter(p, 'PRNs', [], ...
        @(x) isnumeric(x) && isvector(x) && all(isfinite(x)));
    addParameter(p, 'Visible', false, @localLogicalScalar);
    addParameter(p, 'Overwrite', true, @localLogicalScalar);
    addParameter(p, 'Resolution', 150, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(p, 'SaveFigure', false, @localLogicalScalar);
    addParameter(p, 'FontSize', 16, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 8);
    addParameter(p, 'TitleFontSize', 19, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 8);
    addParameter(p, 'ContinueOnError', true, @localLogicalScalar);
    addParameter(p, 'KeepLoadedResults', false, @localLogicalScalar);
    addParameter(p, 'WriteReport', true, @localLogicalScalar);
    parse(p, varargin{:});

    opts = p.Results;
    opts.RunNames = string(opts.RunNames(:));
    opts.RunPattern = char(opts.RunPattern);
    opts.ResultFiles = cellstr(string(opts.ResultFiles(:)));
    opts.OutputSubdir = char(opts.OutputSubdir);
    opts.PRNs = unique(double(opts.PRNs(:).'), 'sorted');
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value) ...
        && isfinite(double(value));
end

function runSources = localDiscoverRuns(rootDir, opts)
    runSources = repmat(struct('runDir', '', 'sourcePath', ''), 0, 1);
    directSource = localFindSource(rootDir, opts.ResultFiles);
    if ~isempty(directSource)
        runSources(1) = struct('runDir', rootDir, ...
            'sourcePath', directSource);
        return;
    end

    candidateDirs = {};
    if opts.Recursive
        for patternIdx = 1:numel(opts.ResultFiles)
            entries = dir(fullfile(rootDir, '**', ...
                opts.ResultFiles{patternIdx}));
            entries = entries(~[entries.isdir]);
            candidateDirs = [candidateDirs, {entries.folder}]; %#ok<AGROW>
        end
        candidateDirs = unique(candidateDirs, 'stable');
    else
        entries = dir(rootDir);
        entries = entries([entries.isdir]);
        entries = entries(~ismember({entries.name}, {'.', '..'}));
        candidateDirs = arrayfun(@(x) fullfile(x.folder, x.name), ...
            entries, 'UniformOutput', false);
    end

    for idx = 1:numel(candidateDirs)
        runDir = candidateDirs{idx};
        runName = localBaseName(runDir);
        if ~isempty(opts.RunPattern) ...
                && isempty(regexp(runName, opts.RunPattern, 'once'))
            continue;
        end
        if ~isempty(opts.RunNames) && ~any(strcmpi(runName, opts.RunNames))
            continue;
        end
        sourcePath = localFindSource(runDir, opts.ResultFiles);
        if ~isempty(sourcePath)
            runSources(end + 1, 1) = struct( ...
                'runDir', runDir, 'sourcePath', sourcePath); %#ok<AGROW>
        end
    end

    if isempty(runSources)
        return;
    end
    names = string({runSources.runDir});
    [~, order] = sort(lower(names));
    runSources = runSources(order);
end

function sourcePath = localFindSource(runDir, patterns)
    sourcePath = '';
    for patternIdx = 1:numel(patterns)
        entries = dir(fullfile(runDir, patterns{patternIdx}));
        entries = entries(~[entries.isdir]);
        if isempty(entries)
            continue;
        end
        [~, order] = sort([entries.datenum], 'descend');
        for entryIdx = order
            candidate = fullfile(entries(entryIdx).folder, ...
                entries(entryIdx).name);
            if localMayContainAcquisition(candidate)
                sourcePath = candidate;
                return;
            end
        end
    end
end

function tf = localMayContainAcquisition(path)
    tf = false;
    try
        vars = whos('-file', path);
        names = {vars.name};
        tf = any(ismember(names, {'acqResults', 'results', ...
            'smoke', 'report', 'acquisitionResults'}));
    catch
    end
end

function [runReport, runData] = localReplayRun(runDir, sourcePath, opts)
    started = tic;
    runReport = localEmptyRunReport();
    runReport.runName = localBaseName(runDir);
    runReport.runDir = runDir;
    runReport.sourcePath = sourcePath;
    runData = localEmptyReplayData();

    outputDir = fullfile(runDir, opts.OutputSubdir);
    if ~isfolder(outputDir)
        [made, message] = mkdir(outputDir);
        if ~made
            error('replayAcquisitionChannels:CreateOutput', ...
                'Cannot create %s: %s', outputDir, message);
        end
    end
    runReport.outputDir = outputDir;

    [acqResults, settings, sourceVariable] = ...
        localLoadAcquisition(sourcePath);
    satelliteList = localSatelliteList(settings, acqResults);
    [acqResults, satelliteList] = localNormalizeLengths( ...
        acqResults, satelliteList);
    if ~isempty(opts.PRNs)
        selected = ismember(satelliteList, opts.PRNs);
        if ~any(selected)
            error('replayAcquisitionChannels:NoSelectedPrn', ...
                'None of the requested PRNs are present in %s.', sourcePath);
        end
        acqResults = localSliceAcquisition(acqResults, find(selected), ...
            numel(satelliteList));
        satelliteList = satelliteList(selected);
    end

    acquiredMask = localAcquiredMask(acqResults, settings);
    acquiredPrns = satelliteList(acquiredMask);
    threshold = localSettingScalar(settings, 'acqThreshold', nan);
    runReport.sourceVariable = sourceVariable;
    runReport.satelliteList = satelliteList;
    runReport.acquiredPrns = acquiredPrns;
    runReport.nSearched = numel(satelliteList);
    runReport.nAcquired = numel(acquiredPrns);
    runReport.acqThreshold = threshold;

    pngPath = fullfile(outputDir, 'acquisition_channels.png');
    figPath = fullfile(outputDir, 'acquisition_channels.fig');
    figureFiles = {};
    if ~opts.Overwrite && isfile(pngPath) ...
            && (~opts.SaveFigure || isfile(figPath))
        figureFiles{end + 1} = pngPath;
        if opts.SaveFigure
            figureFiles{end + 1} = figPath;
        end
        fprintf('  Existing acquisition figure kept: %s\n', pngPath);
    else
        fig = gobjects(0);
        try
            fig = localAcquisitionFigure(acqResults, satelliteList, ...
                acquiredPrns, threshold, runReport.runName, opts);
            exportgraphics(fig, pngPath, 'Resolution', opts.Resolution);
            figureFiles{end + 1} = pngPath;
            if opts.SaveFigure
                savefig(fig, figPath);
                figureFiles{end + 1} = figPath;
            end
            close(fig);
            fprintf('  Plotted %d/%d acquired PRNs -> %s\n', ...
                numel(acquiredPrns), numel(satelliteList), pngPath);
        catch ME
            if ~isempty(fig) && all(isgraphics(fig))
                close(fig);
            end
            runReport.errors(end + 1) = localErrorRecord( ...
                'plot', sourcePath, ME);
            fprintf(2, '  Acquisition plot failed: %s\n', ME.message);
            if ~opts.ContinueOnError
                rethrow(ME);
            end
        end
    end

    runReport.figureFiles = figureFiles;
    runReport.nFigures = numel(figureFiles);
    runReport.elapsedSeconds = toc(started);
    if isempty(runReport.errors)
        runReport.status = 'succeeded';
    else
        runReport.status = 'partial';
    end

    if opts.KeepLoadedResults
        runData.runDir = runDir;
        runData.sourcePath = sourcePath;
        runData.satelliteList = satelliteList;
        runData.acquiredPrns = acquiredPrns;
        runData.acqResults = acqResults;
        runData.settings = settings;
    end

    if opts.WriteReport
        reportPath = fullfile(outputDir, 'replay_report.json');
        runReport.reportPath = reportPath;
        localWriteJson(reportPath, runReport);
    end
end

function [acqResults, settings, sourceVariable] = localLoadAcquisition(path)
    vars = whos('-file', path);
    names = {vars.name};
    settings = struct();
    if any(strcmp(names, 'settings'))
        value = load(path, 'settings');
        if isstruct(value.settings) && isscalar(value.settings)
            settings = value.settings;
        end
    end

    directNames = {'acqResults', 'acquisitionResults'};
    for idx = 1:numel(directNames)
        name = directNames{idx};
        if any(strcmp(names, name))
            value = load(path, name);
            acqResults = value.(name);
            sourceVariable = name;
            [acqResults, settings] = localValidateLoaded( ...
                acqResults, settings, path);
            return;
        end
    end

    wrapperNames = {'results', 'smoke', 'report'};
    for idx = 1:numel(wrapperNames)
        name = wrapperNames{idx};
        if ~any(strcmp(names, name))
            continue;
        end
        value = load(path, name);
        wrapper = value.(name);
        if isstruct(wrapper) && isscalar(wrapper) ...
                && isfield(wrapper, 'acqResults')
            acqResults = wrapper.acqResults;
            if isempty(fieldnames(settings)) && isfield(wrapper, 'settings') ...
                    && isstruct(wrapper.settings) && isscalar(wrapper.settings)
                settings = wrapper.settings;
            end
            sourceVariable = [name '.acqResults'];
            [acqResults, settings] = localValidateLoaded( ...
                acqResults, settings, path);
            return;
        end
    end
    error('replayAcquisitionChannels:BadMat', ...
        'No acquisition result structure was found in %s.', path);
end

function [acqResults, settings] = localValidateLoaded( ...
        acqResults, settings, path)
    if ~isstruct(acqResults) || ~isscalar(acqResults) ...
            || ~isfield(acqResults, 'peakMetric')
        error('replayAcquisitionChannels:BadAcquisition', ...
            'Acquisition result in %s has no peakMetric vector.', path);
    end
    if ~isfield(acqResults, 'peakMetric2') ...
            || isempty(acqResults.peakMetric2)
        acqResults.peakMetric2 = nan(size(acqResults.peakMetric));
    end
    if ~isstruct(settings) || ~isscalar(settings)
        settings = struct();
    end
end

function satelliteList = localSatelliteList(settings, acqResults)
    satelliteList = [];
    if isfield(settings, 'acqSatelliteList')
        satelliteList = localParsePrnList(settings.acqSatelliteList);
    end
    candidateNames = {'satelliteList', 'SatList', 'PRN', 'prn'};
    if isempty(satelliteList)
        for idx = 1:numel(candidateNames)
            name = candidateNames{idx};
            if isfield(acqResults, name)
                satelliteList = localParsePrnList(acqResults.(name));
                if ~isempty(satelliteList)
                    break;
                end
            end
        end
    end
    if isempty(satelliteList)
        satelliteList = 1:numel(acqResults.peakMetric);
    end
    satelliteList = double(satelliteList(:).');
end

function values = localParsePrnList(raw)
    values = [];
    if isnumeric(raw)
        values = raw(isfinite(raw));
        return;
    end
    if iscell(raw)
        try
            raw = strjoin(string(raw), ',');
        catch
            return;
        end
    end
    if ~(ischar(raw) || (isstring(raw) && isscalar(raw)))
        return;
    end
    parts = regexp(char(raw), '[,;\s]+', 'split');
    for idx = 1:numel(parts)
        token = strtrim(parts{idx});
        if isempty(token)
            continue;
        end
        numbers = sscanf(token, '%f:%f:%f');
        if isscalar(numbers)
            values(end + 1) = numbers(1); %#ok<AGROW>
        elseif numel(numbers) == 2
            values = [values, numbers(1):numbers(2)]; %#ok<AGROW>
        elseif numel(numbers) == 3 && numbers(2) ~= 0
            values = [values, numbers(1):numbers(2):numbers(3)]; %#ok<AGROW>
        end
    end
end

function [acqResults, satelliteList] = localNormalizeLengths( ...
        acqResults, satelliteList)
    n = min([numel(satelliteList), numel(acqResults.peakMetric), ...
        numel(acqResults.peakMetric2)]);
    if n < 1
        error('replayAcquisitionChannels:EmptyAcquisition', ...
            'Acquisition result has no plottable satellite metrics.');
    end
    if n ~= numel(satelliteList) ...
            || n ~= numel(acqResults.peakMetric) ...
            || n ~= numel(acqResults.peakMetric2)
        warning('replayAcquisitionChannels:LengthMismatch', ...
            'Truncating acquisition vectors and satellite list to %d.', n);
    end
    acqResults = localSliceAcquisition(acqResults, 1:n, ...
        numel(acqResults.peakMetric));
    satelliteList = satelliteList(1:n);
end

function output = localSliceAcquisition(input, indices, originalLength)
    output = input;
    names = fieldnames(input);
    for idx = 1:numel(names)
        name = names{idx};
        value = input.(name);
        if isvector(value) && numel(value) == originalLength
            output.(name) = value(indices);
        elseif ismatrix(value) && size(value, 2) == originalLength
            output.(name) = value(:, indices);
        elseif ismatrix(value) && size(value, 1) == originalLength
            output.(name) = value(indices, :);
        end
    end
end

function mask = localAcquiredMask(acqResults, settings)
    n = numel(acqResults.peakMetric);
    mask = false(1, n);
    if isfield(acqResults, 'carrFreq') && ~isempty(acqResults.carrFreq)
        detected = acquisitionDetectedMask(acqResults);
        detected = detected(:).';
        detected = detected(1:min(n, numel(detected)));
        mask(1:numel(detected)) = detected;
        return;
    end
    threshold = localSettingScalar(settings, 'acqThreshold', nan);
    metric = double(acqResults.peakMetric(:).');
    if isfinite(threshold)
        mask = isfinite(metric) & metric >= threshold;
    else
        mask = isfinite(metric);
    end
end

function fig = localAcquisitionFigure(acqResults, satelliteList, ...
        acquiredPrns, threshold, runName, opts)
    originalVisibility = get(groot, 'DefaultFigureVisible');
    visibilityCleanup = onCleanup(@() set( ...
        groot, 'DefaultFigureVisible', originalVisibility));
    set(groot, 'DefaultFigureVisible', localOnOff(opts.Visible));
    plotAcquisition(acqResults, satelliteList);
    fig = gcf;
    set(fig, 'Visible', localOnOff(opts.Visible), 'Color', 'w', ...
        'Position', [50 30 1500 1050], ...
        'Name', sprintf('%s acquisition replay', runName));

    axesHandles = findall(fig, 'Type', 'axes');
    for idx = 1:numel(axesHandles)
        ax = axesHandles(idx);
        set(ax, 'FontSize', opts.FontSize, 'LineWidth', 1.1);
        if isgraphics(ax.Title)
            set(ax.Title, 'FontSize', opts.TitleFontSize, ...
                'FontWeight', 'bold');
        end
        if isgraphics(ax.XLabel)
            set(ax.XLabel, 'FontSize', opts.FontSize);
        end
        if isgraphics(ax.YLabel)
            set(ax.YLabel, 'FontSize', opts.FontSize);
        end
        titleText = string(ax.Title.String);
        if isfinite(threshold) && contains(titleText, 'PeakMetric1')
            yline(ax, threshold, '--r', ...
                sprintf('Threshold %.2f', threshold), ...
                'LineWidth', 1.5, 'FontSize', opts.FontSize, ...
                'LabelHorizontalAlignment', 'left');
        end
    end
    legends = findall(fig, 'Type', 'legend');
    set(legends, 'FontSize', max(8, opts.FontSize - 1));
    if isempty(acquiredPrns)
        acquiredText = 'none';
    else
        acquiredText = strjoin(compose('%02d', acquiredPrns), ', ');
    end
    sgtitle(fig, sprintf('%s | searched %d | acquired %d | PRNs: %s', ...
        runName, numel(satelliteList), numel(acquiredPrns), acquiredText), ...
        'Interpreter', 'none', 'FontSize', opts.TitleFontSize + 2, ...
        'FontWeight', 'bold');
    clear visibilityCleanup;
end

function value = localSettingScalar(settings, name, fallback)
    value = fallback;
    if isstruct(settings) && isfield(settings, name)
        candidate = settings.(name);
        if isnumeric(candidate) && isscalar(candidate) && isfinite(candidate)
            value = double(candidate);
        end
    end
end

function data = localEmptyReplayData()
    data = struct('runDir', '', 'sourcePath', '', ...
        'satelliteList', [], 'acquiredPrns', [], 'acqResults', [], ...
        'settings', struct());
end

function report = localEmptyRunReport()
    report = struct( ...
        'runName', '', ...
        'runDir', '', ...
        'sourcePath', '', ...
        'sourceVariable', '', ...
        'outputDir', '', ...
        'status', 'pending', ...
        'satelliteList', [], ...
        'acquiredPrns', [], ...
        'nSearched', 0, ...
        'nAcquired', 0, ...
        'acqThreshold', NaN, ...
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
        error('replayAcquisitionChannels:WriteReport', ...
            'Cannot open replay report for writing: %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, text, 'char');
end

function value = localOnOff(tf)
    if logical(tf)
        value = 'on';
    else
        value = 'off';
    end
end

function name = localBaseName(path)
    [~, name] = fileparts(path);
end

function value = localTextScalar(value, argumentName)
    if ~(ischar(value) || (isstring(value) && isscalar(value)))
        error('replayAcquisitionChannels:TextScalar', ...
            '%s must be a character vector or string scalar.', argumentName);
    end
    value = char(value);
end
